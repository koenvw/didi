Capistrano::Configuration.instance.load do

# =============================================
# Script variables. These must be set in client capfile.
# =============================================
_cset(:db_type)         { abort "Please specify the Drupal database type (:db_type)." }
_cset(:db_name)         { abort "Please specify the Drupal database name (:db_name)." }
_cset(:db_username)     { abort "Please specify the Drupal database username (:db_username)." }
_cset(:db_password)     { abort "Please specify the Drupal database password (:db_password)." }
_cset(:drupal_version)  { abort "Please specify the Drupal version (6 or 7) (:drupal_version)." }

_cset(:profile)         { abort "Please specify the Drupal install profile (:profile)." }
_cset(:site)            { abort "Please specify the Drupal site (:site)." }
_cset(:sitemail)        { abort "Please specify the Drupal site mail (:sitemail)." }
_cset(:adminpass)       { abort "Please specify the Drupal admin password (:adminpass)." }
_cset(:sitesubdir)      { abort "Please specify the Drupal site subdir (:sitemail)." } # FIXME: files folder needs to be symlinked ??
_cset(:baseline)        { abort "Please specify the Baseline feature (:baseline)." } 


# Fixed defaults. Change these at your own risk, (well tested) support for different values is left for future versions.
set :scm,               :git 
set :deploy_via,        :remote_cache
set :drupal_version,    '7'
# Only bother to keep the last five releases
set :keep_releases,     5
set :use_sudo,          false

# ==============================================
# Defaults. You may change these to your projects convenience
# ==============================================
#ssh_options[:verbose] = :debug #FIXME
_cset :domain,          'default'
_cset :db_host,         'localhost'
_cset :drupal_path,     'drupal'
_cset :srv_usr,         'www-data'
#_cset :srv_password,    'www-data' #FIXME

# ===============================================
# Script constants. These should not be changed
# ===============================================
set :settings,          'settings.php'
set :files,             'files'
set :dbbackups,         'db_backups' 
set :shared_children,   [domain, File.join(domain, files)]        

_cset(:shared_settings) { File.join(shared_path, domain, settings) }
_cset(:shared_files)    { File.join(shared_path, domain, files) }
_cset(:dbbackups_path)  { File.join(deploy_to, dbbackups, domain) }
_cset(:drush)           { "drush -r #{current_path}" + (domain == 'default' ? '' : " -l #{domain}") }

_cset(:release_settings)              { File.join(release_path, drupal_path, 'sites', domain, settings) }
_cset(:release_files)                 { File.join(release_path, drupal_path, 'sites', domain, files) }
_cset(:release_domain)                { File.join(release_path, drupal_path, 'sites', domain) }

_cset(:previous_release_settings)     { releases.length > 1 ? File.join(previous_release, drupal_path, 'sites', domain, settings) : nil }
_cset(:previous_release_files)        { releases.length > 1 ? File.join(previous_release, drupal_path, 'sites', domain, files) : nil }
_cset(:previous_release_domain)       { releases.length > 1 ? File.join(previous_release, drupal_path, 'sites', domain) : nil }

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
    cleanup
  end
  #before "deploy:update", "tests:php_lint_test"

  desc "Setup a drupal site from scratch"
  task :cold do
    setup
    update_code
    symlink
  end
  after "deploy:cold", "drush:si"
  
  desc "Deploys latest code and rebuild the database"
  task :rebuild do
    default
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
    dirs = [deploy_to, releases_path, shared_path, dbbackups_path]
    dirs += shared_children.map { |d| File.join(shared_path, d) }
    run <<-CMD
      mkdir -p #{dirs.join(' ')} &&
      #{try_sudo} chown #{user}:#{srv_usr} #{shared_files}
    CMD

    #create drupal config file
    put configuration, shared_settings
  end
  
  desc "Rebuild files and settings symlinks"
  task :finalize_update, :except => { :no_release => true } do
    on_rollback do
      if previous_release
        run "ln -nfs #{shared_files} #{previous_release_files} && ln -nfs #{shared_settings} #{previous_release_settings}"
      else
        logger.important "no previous release to rollback to, rollback of drupal shared data skipped."
      end
    end

    
    run "if [[ ! -d #{release_domain} ]]; then mkdir #{release_domain}; fi" # in case the default is not versioned
    
    run <<-CMD    
      ln -nfs #{shared_files} #{release_files} &&
      ln -nfs #{shared_settings} #{release_settings}
    CMD

    if previous_release
      run "if [[ -d #{previous_release_domain} ]]; then chmod 777 #{previous_release_domain}; fi" # if drupal changed the permissions of the folder
      run <<-CMD
        rm -f #{previous_release_settings} &&
        rm -f #{previous_release_files}
      CMD
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
  
  desc "Revert all enabled feature module on your site"
  task :fra do
    run "cd #{current_path}/#{drupal_path} && drush features-revert-all -y"
  end
  
  desc "Install Drupal along with modules/themes/configuration using the specified install profile"
  task :si do
    dburl = "#{db_type}://#{db_username}:#{db_password}@localhost/#{db_name}"
    run "cd #{current_path}/#{drupal_path} && drush site-install #{profile} --db-url=#{dburl} --sites-subdir=default --account-name=admin --account-pass=#{adminpass}  --account-mail=#{sitemail} --site-mail='#{sitemail}' --site-name='#{site}' -y" 
    bl
  end
  
  desc "Enable the baseline feature"
  task :bl do
    run "cd #{current_path}/#{drupal_path} && drush pm-enable #{baseline} -y"
    cc
  end
  
  desc "Apply any database updates required (as with running update.php)"
  task :updb do
    run "cd #{current_path}/#{drupal_path} && drush updatedb -y"
  end
  
  desc "Update via drush, runs fra, updb and cc"
  task :update do
    fra
    updb
    cc
  end
  
  after "deploy:symlink", "drush:update"
  #after "deploy:setup", "drush:si"

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
    test_files = Dir.glob( File.join( drupal_path, 'sites', '**', '*.test' ) )
    puts test_files
    if test_files.any?
      test_files.each do |test_file|
        fail 'Unit tests failed' unless system("php ./drupal/scripts/run-tests.sh --url http://#{site} --file '#{test_file}'")
      end
    end
  end
  
end

# =========================
# Helper methods
# =========================

# Builds initial contents of the Drupal website's settings file
def drupal_settings(version)
  if version == '6'
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