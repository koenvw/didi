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

set :domain,            'default'
set :db_host,           'localhost'
set :drupal_path,       'drupal'
set :srv_usr,           'www-data'
set :enable_robots,     false
set :no_disable,        true
set :local_database,    nil
set :backup_database,   true
set :push_dump_enabled, false

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
_cset :drush_path,        ''

_cset(:shared_settings) { domain.to_a.map { |d| File.join(shared_path, d, settings) } }
_cset(:shared_files)    { domain.to_a.map { |d| File.join(shared_path, d, files) } }
_cset(:dbbackups_path)  { domain.to_a.map { |d| File.join(deploy_to, dbbackups, d) } }
_cset(:drush)           { "drush -r #{current_path}" + (domain == 'default' ? '' : " -l #{domain}") }  # FIXME: not in use?

_cset(:release_settings)              { domain.to_a.map { |d| File.join(release_path, drupal_path, 'sites', d, settings) } }
_cset(:release_files)                 { domain.to_a.map { |d| File.join(release_path, drupal_path, 'sites', d, files) } }
_cset(:release_domain)                { domain.to_a.map { |d| File.join(release_path, drupal_path, 'sites', d) } }

_cset(:previous_release_settings)     { releases.length > 1 ? domain.to_a.map { |d| File.join(previous_release, drupal_path, 'sites', d, settings) } : nil }
_cset(:previous_release_files)        { releases.length > 1 ? domain.to_a.map { |d| File.join(previous_release, drupal_path, 'sites', d, files) } : nil }
_cset(:previous_release_domain)       { releases.length > 1 ? domain.to_a.map { |d| File.join(previous_release, drupal_path, 'sites', d) } : nil }

_cset(:is_multisite)                  { domain.to_a.size > 1 }

# =========================================================================
# Extra dependency checks
# =========================================================================
depend :local,  :command, "drush"
depend :remote, :command, "#{drush_path}drush"


# =========================================================================
# Overwrites to the DEPLOY tasks in the capistrano library.
# =========================================================================

namespace :deploy do

  desc <<-DESC
    Deploys your Drupal site, runs drush:update. It supposes that the Setup task was already executed.
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
      update
    end
  end
  after "deploy:cold", "drush:si"

  desc "Deploys latest code and rebuild the database"
  task :rebuild do
    update
    manage.dbdump_previous
    cleanup
  end
  after "deploy:rebuild", "drush:si"

 desc <<-DESC
    Prepares one or more servers for deployment.
    Creates the necessary file structure and the shared Drupal settings file.
  DESC
  task :setup, :except => { :no_release => true } do
    #Create shared directories
    # FIXME: chown / chmod require user to be member of
    dirs = [deploy_to, releases_path, shared_path, dbbackups_path, shared_files]
    dirs += domain.map { |d| File.join(shared_path, d) }

    run <<-CMD
      mkdir -p #{dirs.join(' ')} && #{try_sudo} chown #{user}:#{srv_usr} #{shared_files.join(' ')} && #{try_sudo} chmod g+w #{shared_files.join(' ')}
    CMD

    #create drupal config file
    domain.each_with_index do |d, i|
      configuration = drupal_settings(drupal_version, d)
      put configuration, shared_settings[i]
    end

  end

  desc "[internal] Rebuild files and settings symlinks"
  task :finalize_update, :except => { :no_release => true } do
    # Specifies an on_rollback hook for the currently executing task. If this
    # or any subsequent task then fails, and a transaction is active, this
    # hook will be executed.
    on_rollback do
      if previous_release
        #FIXME: won't work on mulitsite config
        run "ln -nfs #{shared_files} #{previous_release_files} && ln -nfs #{shared_settings} #{previous_release_settings}"
      else
        logger.important "no previous release to rollback to, rollback of drupal shared data skipped."
      end
    end

    release_domain.each do |rd|
      run "if [ ! -d #{rd} ]; then mkdir #{rd}; fi" # in case the default folder is not versioned
    end

    shared_files.each_with_index do |sf, i|
      run <<-CMD
        ln -nfs #{sf} #{release_files[i]} &&
        ln -nfs #{shared_settings[i]} #{release_settings[i]}
        CMD
    end
  end

  desc "[internal] cleanup old symlinks, must run after deploy:symlink"
  task :cleanup_shared_symlinks, :except => { :no_release => true } do
    if previous_release
      # FIXME: executes on initial deploy:cold?
      # FIXME: this breaks the current site until deploy:symlink is executed ?
      previous_release_domain.each_with_index do |prd, i|
        run "if [ -d #{prd} ]; then chmod 777 #{prd}; fi" # if drupal changed the permissions of the folder
        run <<-CMD
          rm -f #{previous_release_settings[i]} &&
          rm -f #{previous_release_files[i]}
        CMD
      end
    end
  end
  after "deploy:symlink", "deploy:cleanup_shared_symlinks"

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
      databases = dbbackups_path.product(old_releases.map { |release| "#{release}.sql"} ).map { |p| File.join(p)}.join(" ") if backup_database
      run "rm -rf #{directories} #{databases}"
    end
  end

  namespace :rollback do

    desc <<-DESC
    go back to the previous release (code and database)
    DESC
    task :default do
      revision
      #db_rollback if domain.to_a.size == 1 # FIXME: not supported in multisite configuration, does not work
      cleanup
    end

    desc <<-DESC
      [internal] Removes the most recently deployed release.
      This is called by the rollback sequence, and should rarely
      (if ever) need to be called directly.
    DESC
    task :cleanup, :except => { :no_release => true } do
      # FIXME: this doesn't cleanup dbbackups
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
        CMD
        shared_files.each_with_index do |sf, i|
          run <<-CMD
            ln -nfs #{sf} #{previous_release_files[i]} &&
            ln -nfs #{shared_settings[i]} #{previous_release_settings[i]}
          CMD
        end
      else
        abort "could not rollback the code because there is no prior release"
      end
    end


    desc <<-DESC
    [internal] If a database backup from the previous release is found, dump the current
    database and import the backup. This task should NEVER be called standalone.
    DESC
    task :db_rollback, :except => { :no_release => true } do
      #FIXME: does not work
      if previous_release
        logger.info "Dumping current database and importing previous one (If one is found)."
        previous_db = File.join(dbbackups_path, "#{releases[-2]}.sql")
        import_cmd = "cd #{previous_release}/#{drupal_path} && drush sql-drop -y && drush sql-cli < #{previous_db} && rm #{previous_db}"
        run "if [ -e #{previous_db} ]; then #{import_cmd}; fi"
      else
        abort "could not rollback the database because there is no prior release db backups"
      end
    end

  end
  
  namespace :web do
    desc "Makes the application web-accessible again."
    task :enable do
      drush.ensite
    end
    desc "Present a maintenance page to visitors."
    task :disable do
      drush.dissite
    end
  end

end

# =========================
# Drush namespace tasks
# =========================
namespace :drush do

  desc "Clear the Drupal site cache"
  task :cc do
    domain.each do |d|
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " cache-clear all"
    end
  end

  desc "Show features diff status"
  task :fd do
    domain.each do |d|
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " features-diff"
    end
  end

  desc "Revert all enabled feature modules on your site"
  task :fra do
    domain.each do |d|
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " features-revert-all -y"
    end
  end

  desc "Force revert all enabled feature modules on your site"
  task :fraforce do
    domain.each do |d|
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " features-revert-all --force -y"
    end
  end

  desc "Install Drupal along with modules/themes/configuration using the specified install profile"
  task :si do
    domain.each do |d|
      dburl = "#{db_type}://#{db_username}:#{db_password}@#{db_host}/#{db_name.gsub("%domain", d)}"
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush site-install #{profile} --db-url=#{dburl} --sites-subdir=#{d} --account-name=admin --account-pass=#{adminpass}  --account-mail=#{sitemail} --site-mail='#{sitemail}' --site-name='#{site.gsub("%domain", d)}' -y"
    end
    bl
  end

  desc "[internal] Enable the baseline feature"
  task :bl do
    domain.each do |d|
      baseline.to_a.each do |bl_item|
        run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " pm-enable #{bl_item.gsub("%domain", d)} -y"
      end
    end
    cc
  end
  desc "[internal] Enable the simpletest feature"
  task :enst do
    run "cd #{current_path}/#{drupal_path} && #{drush_path}drush pm-enable simpletest -y"
    cc
  end

  desc "[internal] Disable maintenance mode, enabling the site"
  task :ensite do
    if drupal_version == 6
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush vset --always-set site_offline 0"
    else
      domain.each do |d|
        run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " vset --always-set maintenance_mode 0"
      end
    end
  end

  desc "[internal] Enable maintenance mode, disabling the site"
  task :dissite do
    if drupal_version == 6
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush vset --always-set site_offline 1"
    else
      domain.each do |d|
        run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " vset --always-set maintenance_mode 1"
      end
    end
  end

  desc "Apply any database updates required (as with running update.php)"
  task :updb do
    domain.each do |d|
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " updatedb -y"
    end
  end

  desc "Update via drush, runs fra, updb and cc"
  task :update do
    dissite unless no_disable
    updb # database updates (also handles modules that have been moved around)
    cc # fix for user_permissions constraint (install new modules)
    fra # reverts all features
    cc # clear cache (required for new menu items, hook_menu)
    ensite unless no_disable
    manage.block_robots unless enable_robots
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

  desc "Block bots via robots.txt"
  task :block_robots do
    put "User-agent: *\nDisallow: /", "#{current_path}/#{drupal_path}/robots.txt"
  end

  task :dbdump_previous do
    #Backup the previous release's database
    if previous_release && backup_database
      domain.each_with_index do |d,i|
        run "cd #{current_path}/#{drupal_path} && #{drush_path}drush" + (d == 'default' ? '' : " -l #{d}") + " sql-dump > #{ File.join(dbbackups_path[i], "#{releases[-2]}.sql") }"
      end
    end
  end

  desc 'Dump remote database and restore locally'
  task :pull_dump do
    abort("ERROR: multisite not supported") if is_multisite
    abort("NO LOCAL DATABASE FOUND, set :local_database in the config file..") unless local_database

    set(:runit, Capistrano::CLI.ui.ask("WARNING!! will overwrite this local database: '#{local_database}', type 'yes' to continue: "))
    if runit == 'yes'
      sql_file = File.join(dbbackups_path, "#{releases.last}-pull.sql")
      # dump & gzip remote file
      run "cd #{current_path}/#{drupal_path} && #{drush_path}drush sql-dump > #{sql_file} && gzip -f #{sql_file}"
      # copy to local
      system "if [ ! -d build ]; then mkdir build; fi" # create build folder locally if needed
      download "#{sql_file}.gz", "build/", :once => true, :via => :scp
      run "rm #{sql_file}.gz"
      # extract and restore
      system "gunzip -f build/#{File.basename(sql_file)}.gz && echo \"DROP DATABASE #{local_database};CREATE DATABASE #{local_database}\" | mysql && mysql #{local_database} < build/#{File.basename(sql_file)}" if local_database
      # check if file sanitation sql file exists
      if File.exists?("config/sql/#{stage}.sql")
        puts "  * executing \"config/sql/#{stage}.sql\""
        system "mysql #{local_database} < config/sql/#{stage}.sql"
      end
    end
  end

  desc 'Dump local database and restore remote'
  task :push_dump do
    abort("ERROR: multisite not supported") if is_multisite
    abort("NO LOCAL DATABASE FOUND, set :local_database in the config file..") unless local_database
    abort("THIS STAGE: #{stage} DOES NOT SUPPORT manage:push_dump") unless push_dump_enabled

    set(:runit, Capistrano::CLI.ui.ask("WARNING!! will overwrite this REMOTE database: '#{db_name}', type 'yes' to continue: "))
    if runit == 'yes'
      sql_file = "#{Time.now.to_i}.sql"
      system "if [ ! -d build ]; then mkdir build; fi" # create build folder locally if needed
      # dump & gzip local file
      system "cd #{drupal_path} && drush sql-dump > ../build/#{sql_file} && gzip ../build/#{sql_file}"
      # copy to remote
      upload "build/#{sql_file}.gz", File.join(dbbackups_path, "#{sql_file}.gz"), :once => true, :via => :scp
      system "rm build/#{sql_file}.gz"
      # extract and restore
      run "gunzip -f #{File.join(dbbackups_path, "#{sql_file}.gz")} && cd #{current_path}/#{drupal_path} && #{drush_path}drush sql-cli < #{File.join(dbbackups_path, "#{sql_file}")}"
      run "rm  #{File.join(dbbackups_path, "#{sql_file}")}"
    end
  
  end
end


# =========================
# Helper methods
# =========================

# Builds initial contents of the Drupal website's settings file
def drupal_settings(version, domain)
  db_domain_name = db_name.gsub("%domain", domain)
  if version.to_s == '6'
    settings = <<-STRING
<?php
$db_url = "#{db_type}://#{db_username}:#{db_password}@#{db_host}/#{db_domain_name}";
ini_set('arg_separator.output',     '&amp;');
ini_set('magic_quotes_runtime',     0);
ini_set('magic_quotes_sybase',      0);
ini_set('session.cache_expire',     200000);
ini_set('session.cache_limiter',    'none');
ini_set('session.cookie_lifetime',  2000000);
ini_set('session.gc_probability', 1);
ini_set('session.gc_maxlifetime',   200000);
ini_set('session.save_handler',     'user');
ini_set('session.use_cookies',      1);
ini_set('session.use_only_cookies', 1);
ini_set('session.use_trans_sid',    0);
ini_set('url_rewriter.tags',        '');
    STRING
  elsif version == '7'
    settings = <<-STRING
<?php
$databases = array ('default' => array ('default' => array (
  'database' => '#{db_domain_name}',
  'username' => '#{db_username}',
  'password' => '#{db_password}',
  'host' => '#{db_host}',
  'port' => '',
  'driver' => '#{db_type}',
  'prefix' => '',
)));
ini_set('session.gc_probability', 1);
ini_set('session.gc_divisor', 100);
ini_set('session.gc_maxlifetime', 200000);
ini_set('session.cookie_lifetime', 2000000);

// Allow local env to override settings by creating a local.settings.php.
$path = str_replace('settings.php', 'local.settings.php', __FILE__);

if (file_exists($path)) {
  include_once($path);
}

    STRING
  else
    abort "Unsupported Drupal version #{version}."
  end
end

end # Capistrano::Configuration.instance.load