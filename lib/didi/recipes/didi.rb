Capistrano::Configuration.instance.load do

#require 'FileUtils'

# =========================================================================
# These variables MUST be set in the client capfiles. If they are not set,
# the deploy will fail with an error.
# =========================================================================
_cset(:db_type)         { abort "Please specify the Drupal database type (:db_type)." }
_cset(:db_name)         { abort "Please specify the Drupal database name (:db_name)." }
_cset(:db_username)     { abort "Please specify the Drupal database username (:db_username)." }
_cset(:db_password)     { abort "Please specify the Drupal database password (:db_password)." }

_cset(:profile)         { abort "Please specify the Drupal install profile (:profile)." }
_cset(:site)            { abort "Please specify the Drupal site (:site)." }
_cset(:sitemail)        { abort "Please specify the Drupal site mail (:sitemail)." }
_cset(:adminpass)       { abort "Please specify the Drupal admin password (:adminpass)." }
_cset(:sitesubdir)      { abort "Please specify the Drupal site subdir (:sitesubdir)." } # FIXME: files folder needs to be symlinked ??
_cset(:baseline)        { abort "Please specify the Baseline feature (:baseline)." }


# =========================================================================
# These variables may be set in the client capfile if their default values
# are not sufficient.
# =========================================================================
set :scm,               :git
set :deploy_via,        :remote_cache
set :drupal_version,    '7'
set :keep_releases,     5
set :use_sudo,          false

set :domain,          'default'
set :db_host,         'localhost'
set :drupal_path,     'drupal'
set :srv_usr,         'www-data'

ssh_options[:forward_agent] = true
#ssh_options[:verbose] = :debug #FIXME

# =========================================================================
# These variables should NOT be changed unless you are very confident in
# what you are doing. Make sure you understand all the implications of your
# changes if you do decide to muck with these!
# =========================================================================
_cset :settings,          'settings.php'
_cset :files,             'files'
_cset :dbbackups,         'db_backups'
_cset :shared_children,   [domain, File.join(domain, files)]

_cset(:shared_settings) { File.join(shared_path, domain, settings) }
_cset(:shared_files)    { File.join(shared_path, domain, files) }
_cset(:dbbackups_path)  { File.join(deploy_to, dbbackups, domain) }
_cset(:drush)           { "drush -r #{current_path}" + (domain == 'default' ? '' : " -l #{domain}") }  # FIXME: not in use?

_cset(:release_settings)              { File.join(release_path, drupal_path, 'sites', domain, settings) }
_cset(:release_files)                 { File.join(release_path, drupal_path, 'sites', domain, files) }
_cset(:release_domain)                { File.join(release_path, drupal_path, 'sites', domain) }

_cset(:previous_release_settings)     { releases.length > 1 ? File.join(previous_release, drupal_path, 'sites', domain, settings) : nil }
_cset(:previous_release_files)        { releases.length > 1 ? File.join(previous_release, drupal_path, 'sites', domain, files) : nil }
_cset(:previous_release_domain)       { releases.length > 1 ? File.join(previous_release, drupal_path, 'sites', domain) : nil }

# =========================================================================
# Extra dependecy checks
# =========================================================================
depend :local,  :command, "drush"
depend :remote, :command, "drush"


# =========================================================================
# Overwrites to the DEPLOY tasks in the capistrano library.
# =========================================================================

namespace :deploy do

  desc <<-DESC
    Deploys your Drupal site. It supposes that the Setup task was already executed.
    This overrides the default Capistrano Deploy task to handle database operations and backups,
    all of them via Drush.
  DESC
  task :default do
    update
    manage.dbdump_previous
    cleanup
  end
  after "deploy", "drush:update"

  desc "Setup a drupal site from scratch"
  task :cold do
    transaction do
      setup
      update_code
      symlink
    end
  end
  after "deploy:cold", "drush:si"

  desc "Deploys latest code and rebuild the database"
  task :rebuild do
    update_code
    symlink
    manage.dbdump_previous
  end
  after "deploy:rebuild", "drush:si"

 desc <<-DESC
    Prepares one or more servers for deployment.
    Creates the necessary file structure and the shared Drupal settings file.
  DESC
  task :setup, :except => { :no_release => true } do
    #try to create configuration file before writing directories to server
    configuration = drupal_settings(drupal_version)

    #Create shared directories
    dirs = [deploy_to, releases_path, shared_path, dbbackups_path, shared_files]
    dirs += shared_children.map { |d| File.join(shared_path, d) }
    run <<-CMD
      mkdir -p #{dirs.join(' ')} &&
      #{try_sudo} chown #{user}:#{srv_usr} #{shared_files} &&
      #{try_sudo} chmod g+w #{shared_files}
    CMD

    #create drupal config file
    put configuration, shared_settings
  end

  desc "[internal] Rebuild files and settings symlinks"
  task :finalize_update, :except => { :no_release => true } do
    on_rollback do
      if previous_release
        run "ln -nfs #{shared_files} #{previous_release_files} && ln -nfs #{shared_settings} #{previous_release_settings}"
      else
        logger.important "no previous release to rollback to, rollback of drupal shared data skipped."
      end
    end


    run "if [ ! -d #{release_domain} ]; then mkdir #{release_domain}; fi" # in case the default is not versioned

    run <<-CMD
      ln -nfs #{shared_files} #{release_files} &&
      ln -nfs #{shared_settings} #{release_settings}
    CMD

    if previous_release
      run "if [ -d #{previous_release_domain} ]; then chmod 777 #{previous_release_domain}; fi" # if drupal changed the permissions of the folder
      run <<-CMD
        rm -f #{previous_release_settings} &&
        rm -f #{previous_release_files}
      CMD
    end
  end

  desc <<-DESC
    Removes old releases and corresponding DB backups.
  DESC
  task :cleanup, :except => { :no_release => true } do
    count = fetch(:keep_releases, 5).to_i
    if count >= releases.length
      logger.important "No old releases to clean up"
    else
      logger.info "keeping #{count} of #{releases.length} deployed releases"
      old_releases = (releases - releases.last(count))
      directories = old_releases.map { |release| File.join(releases_path, release) }.join(" ")
      databases = old_releases.map { |release| File.join(dbbackups_path, "#{release}.sql") }.join(" ")

      run "rm -rf #{directories} #{databases}"
    end
  end

  namespace :rollback do

    desc <<-DESC
      [internal] Removes the most recently deployed release.
      This is called by the rollback sequence, and should rarely
      (if ever) need to be called directly.
    DESC
    task :cleanup, :except => { :no_release => true } do
      # chmod 777 #{release_settings} #{release_files} &&
      run "if [ `readlink #{current_path}` != #{current_release} ]; then rm -rf #{current_release}; fi"
    end

    desc <<-DESC
    [internal] Points the current, files, and settings symlinks at the previous revision.
    DESC
    task :revision, :except => { :no_release => true } do
      if previous_release
        run <<-CMD
          rm #{current_path};
          ln -s #{previous_release} #{current_path};
          ln -nfs #{shared_files} #{previous_release_files};
          ln -nfs #{shared_settings} #{previous_release_settings}
        CMD
      else
        abort "could not rollback the code because there is no prior release"
      end
    end


    desc <<-DESC
    [internal] If a database backup from the previous release is found, dump the current
    database and import the backup. This task should NEVER be called standalone.
    DESC
    task :db_rollback, :except => { :no_release => true } do
      if previous_release
        logger.info "Dumping current database and importing previous one (If one is found)."
        previous_db = File.join(dbbackups_path, "#{releases[-2]}.sql")
        import_cmd = "cd #{previous_release}/#{drupal_path} && drush sql-drop -y && drush sql-cli < #{previous_db} && rm #{previous_db}"
        run "if [ -e #{previous_db} ]; then #{import_cmd}; fi"
      else
        abort "could not rollback the database because there is no prior release db backups"
      end
    end

    desc <<-DESC
    go back to the previous release (code and database)
    DESC
    task :default do
      revision
      db_rollback
      cleanup
    end

  end

end

# =========================
# Drush namespace tasks
# =========================
namespace :drush do

  desc "Clear the Drupal site cache"
  task :cc do
    run "cd #{current_path}/#{drupal_path} && drush cache-clear all"
  end

  desc "Revert all enabled feature modules on your site"
  task :fra do
    run "cd #{current_path}/#{drupal_path} && drush features-revert-all -y"
  end

  desc "Install Drupal along with modules/themes/configuration using the specified install profile"
  task :si do
    dburl = "#{db_type}://#{db_username}:#{db_password}@#{db_host}/#{db_name}"
    run "cd #{current_path}/#{drupal_path} && drush site-install #{profile} --db-url=#{dburl} --sites-subdir=default --account-name=admin --account-pass=#{adminpass}  --account-mail=#{sitemail} --site-mail='#{sitemail}' --site-name='#{site}' -y"
    bl
  end

  desc "[internal] Enable the baseline feature"
  task :bl do
    run "cd #{current_path}/#{drupal_path} && drush pm-enable #{baseline} -y"
    cc
  end
  desc "[internal]  Enable the simpletest feature"
  task :enst do
    run "cd #{current_path}/#{drupal_path} && drush pm-enable simpletest -y"
    cc
  end

  desc "Apply any database updates required (as with running update.php)"
  task :updb do
    run "cd #{current_path}/#{drupal_path} && drush updatedb -y"
  end

  desc "Update via drush, runs fra, updb and cc"
  task :update do
    updb
    fra
    cc
  end

end

# =========================
# Tests methods
# =========================

namespace :tests do

  desc "Test php lint"
  task :php_lint_test do
    errors = []
    test_files = Dir.glob( File.join( drupal_path, 'sites', '**', '*.{engine,inc,info,install,make,module,php,profile,test,theme,tpl,xtmpl}' ) )
    if test_files.any?
      test_files.each do |test_file|
        begin
          fail unless system("php -l '#{test_file}' > /dev/null")
        rescue
          errors << test_file
        end
      end
    end
    puts "Commit tests failed on files:\n" + errors.join( "\n" ) unless errors.empty?
    exit 1 unless errors.empty?
  end

  desc "Core hack detection"
  task :checksum_core_test do

  end

  desc 'Runs unit tests for given site'
  task :unit do
    run "mkdir -p #{current_path}/build/simpletest"
    test_files = Dir.glob( File.join( drupal_path, 'sites', '**', '*.test' ) )
    test_files.map! {|f| f.sub!(drupal_path + "/","")}
    if test_files.any?
      test_files.each do |test_file|
        run "cd #{current_path}/#{drupal_path} && php scripts/run-tests.sh --url http://#{site} --xml '../build/simpletest' --file '#{test_file}'" unless test_file.include?('/contrib/')
      end
    end

    run "cd #{current_path}/build && tar czf simpletest.tgz simpletest"
    system "if [ ! -d build ]; then mkdir build; fi" # create build folder locally if needed
    download "#{current_path}/build/simpletest.tgz", "build/", :once => true, :via => :scp
    system "tar xzf build/simpletest.tgz -C build"

  end
  before "tests:unit", "drush:enst"

  desc 'Runs all unit tests for given site'
  task :unit_all do
    run "mkdir -p #{current_path}/build/simpletest"
    run "cd #{current_path}/#{drupal_path} && php scripts/run-tests.sh --url http://#{site} --xml '../build/simpletest' --all"

    run "cd #{current_path}/build && tar czf simpletest.tgz simpletest"
    system "if [ ! -d build ]; then mkdir build; fi" # create build folder locally if needed
    download "#{current_path}/build/simpletest.tgz", "build/", :once => true, :via => :scp
    system "tar xzf build/simpletest.tgz -C build"

  end
  before "tests:unit_all", "drush:enst"

end

# =========================
# Manage methods
# =========================

namespace :manage do

  task :block_robots do
    put "User-agent: *\nDisallow: /", "#{current_path}/#{drupal_path}/robots.txt"
  end

  task :dbdump_previous do
    #Backup the previous release's database
    if previous_release
      run "cd #{current_path}/#{drupal_path} && drush sql-dump > #{ File.join(dbbackups_path, "#{releases[-2]}.sql") }"
    end
  end

  desc 'Dump remote database and restore locally'
  task :pull_dump do
    sql_file = File.join(dbbackups_path, "#{releases.last}-pull.sql")
    # dump & gzip remote file
    run "cd #{current_path}/#{drupal_path} && drush sql-dump > #{sql_file} && gzip -f #{sql_file}"
    # copy to local
    system "if [ ! -d build ]; then mkdir build; fi" # create build folder locally if needed
    download "#{sql_file}.gz", "build/", :once => true, :via => :scp
    run "rm #{sql_file}.gz"
    # extract and restore
    system "gunzip -f build/#{File.basename(sql_file)}.gz && mysql dotproject_oa_live < build/#{File.basename(sql_file)}"
  end

  task :push_dump do

  end
end


# =========================
# Helper methods
# =========================

# Builds initial contents of the Drupal website's settings file
def drupal_settings(version)
  if version.to_s == '6'
    settings = <<-STRING
<?php
  $db_url = "#{db_type}://#{db_username}:#{db_password}@#{db_host}/#{db_name}";
    STRING
  elsif version == '7'
    settings = <<-STRING
<?php
  $databases = array ('default' => array ('default' => array (
    'database' => '#{db_name}',
    'username' => '#{db_username}',
    'password' => '#{db_password}',
    'host' => '#{db_host}',
    'port' => '',
    'driver' => '#{db_type}',
    'prefix' => '',
  )));
    STRING
  else
    abort "Unsupported Drupal version #{version}."
  end
end

end