# 
# Cookbook Name:: lb_aicache
#

include RightScale::LB::Helper

action :install do

log "Installing aiCache"

  # Install OpenSSL dependencies
  package "openssl-devel" do
    action :install
  end

  # Assure that there is postfix installed for alerts
  package "postfix" do
    action :install
  end

  # Install aiCache software.
  bash "install_aicache" do
    user "root"
    cwd "/tmp"
    code <<-EOH
    aiInstallDir="/usr/local/aicache"
    aiURL="http://aicache.com/aicache.rb.tar"
    curl -sO $aiURL
    tar -xf aicache.rb.tar
    cd aicache
    chmod +x install.sh
    ./install.sh
    mv $aiInstallDir/aicache_https $aiInstallDir/aicache
    chmod +x $aiInstallDir/*.sh
    chmod +x $aiInstallDir/*.pl
    EOH
  end

  # Creates /etc/aicache directory.
  directory "/etc/aicache" do
    owner "aicache"
    group "aicache"
    mode "0755"
    recursive true
    action :create
  end

  # Creates /etc/aicache/node.d directory.
  directory "/etc/aicache/#{node[:lb][:service][:provider]}.d" do
    owner "aicache"
    group "aicache"
    mode "0755"
    recursive true
    action :create
  end

  # Create reload files for aicache
  file "/usr/local/aicache/reload" do
    owner "aicache"
    group "aicache"
    mode "600"
    action :create_if_missing
  end
  file "/usr/local/aicache/reload_success" do
    owner "aicache"
    group "aicache"
    mode "600"
    action :create_if_missing
  end
  file "/usr/local/aicache/reload_fail" do
    owner "aicache"
    group "aicache"
    mode "600"
    action :create_if_missing
  end

  # Install aiCache start/stop/restart script
  template "/etc/init.d/aicache" do
    source "aicache_restart.sh.erb"
    mode "0755"
    cookbook "lb_aicache"
  end

  service "aicache" do
    supports :reload => true, :restart => true, :status => true, :start => true, :stop => true
    action :enable
  end

  # Install aiCache default config
  template "/etc/aicache/aicache.cfg" do
    source "aicache.cfg.default.erb"
    cookbook "lb_aicache"
    owner "aicache"
    notifies :restart, resources(:service => "aicache")
  end

  # Installs script that concatenates individual server files after the aicache
  # config head into the aicache config.
  cookbook_file "/etc/aicache/aicache-cat.sh" do
    owner "aicache"
    group "aicache"
    mode "0755"
    source "aicache-cat.sh"
    cookbook "lb_aicache"
  end

  # Installs the aicache config head which is the part of the aicache config
  # that doesn't change.
  template "/etc/aicache/aicache.cfg.head" do
    source "aicache.cfg.head.erb"
    cookbook "lb_aicache"
    owner "aicache"
    group "aicache"
    mode "0400"
    stats_uri_line = "stat_url #{node[:lb][:stats_uri]}" unless "#{node[:lb][:stats_uri]}".empty?
    variables(
       :stats_uri => stats_uri_line
    )
  end

  # Generates the aicache config file.
  execute "/etc/aicache/aicache-cat.sh" do
    user "aicache"
    group "aicache"
    umask "0077"
    notifies :start, resources(:service => "aicache")
  end
end

action :add_vhost do

  pool_name = new_resource.pool_name

  # Creates the directory for vhost server files.
  directory "/etc/aicache/#{node[:lb][:service][:provider]}.d/#{pool_name}" do
    owner "aicache"
    group "aicache"
    mode "0755"
    recursive true
    action :create
  end

  # Adds current pool to pool_list conf to preserve lb/pools order
  template "/etc/aicache/#{node[:lb][:service][:provider]}.d/pool_list.conf" do
     source "aicache_backend_list.erb"
     owner "aicache"
     group "aicache"
     mode "0600"
     backup false
     cookbook "lb_aicache"
     variables(
       :pool_list => node[:lb][:pools]
     )
  end

  # See cookbooks/lb_aicache/definitions/aicache_backend.rb for the definition
  # of "lb_aicache_backend".
  lb_aicache_backend  "create main backend section" do
    pool_name  pool_name
  end

  # Calls the "advanced_configs" action.
#  action_advanced_configs

  # (Re)generates the aicache config file.
  execute "/etc/aicache/aicache-cat.sh" do
    user "aicache"
    group "aicache"
    umask "0077"
    action :run
    notifies :reload, resources(:service => "aicache")
  end

  # Tags this server as a load balancer for vhosts it will answer for so app servers
  # can send requests to it.
  # See http://support.rightscale.com/12-Guides/Chef_Cookbooks_Developer_Guide/Chef_Resources#RightLinkTag for the "right_link_tag" resource.
  right_link_tag "loadbalancer:#{pool_name}=lb"

end


action :attach do

  pool_name = new_resource.pool_name

  log "  Attaching #{new_resource.backend_id} / #{new_resource.backend_ip} / #{pool_name}"

  # Creates aicache service.
  service "aicache" do
    supports :reload => true, :restart => true, :status => true, :start => true, :stop => true
    action :nothing
  end

  # Creates the directory for vhost server files.
  directory "/etc/aicache/#{node[:lb][:service][:provider]}.d/#{pool_name}" do
    owner "aicache"
    group "aicache"
    mode "0755"
    recursive true
    action :create
  end

  # (Re)generates the aicache config file.
  execute "/etc/aicache/aicache-cat.sh" do
    user "aicache"
    group "aicache"
    umask "0077"
    action :nothing
    notifies :reload, resources(:service => "aicache")
  end

  # Creates an individual server file for each vhost and notifies the concatenation script if necessary.
  template ::File.join("/etc/aicache/#{node[:lb][:service][:provider]}.d", pool_name, new_resource.backend_id) do
    source "aicache_server.erb"
    owner "aicache"
    group "aicache"
    mode "0600"
    backup false
    cookbook "lb_aicache"
    variables(
      :backend_name => new_resource.backend_id,
      :backend_ip => new_resource.backend_ip,
      :backend_port => new_resource.backend_port
    )
    notifies :run, resources(:execute => "/etc/aicache/aicache-cat.sh")
  end
end

action :attach_request do

  pool_name = new_resource.pool_name

  log "  Attach request for #{new_resource.backend_id} / #{new_resource.backend_ip} / #{pool_name}"

  # Runs remote_recipe for each vhost the app server wants to be part of.
  # See http://support.rightscale.com/12-Guides/Chef_Cookbooks_Developer_Guide/Chef_Resources#RemoteRecipe for the "remote_recipe" resource.
  remote_recipe "Attach me to load balancer" do
    recipe "lb::handle_attach"
    attributes :remote_recipe => {
      :backend_ip => new_resource.backend_ip,
      :backend_id => new_resource.backend_id,
      :backend_port => new_resource.backend_port,
      :pools => pool_name
    }
    recipients_tags "loadbalancer:#{pool_name}=lb"
  end

end


action :detach do

  pool_name = new_resource.pool_name
  backend_id = new_resource.backend_id

  log "  Detaching #{backend_id} from #{pool_name}"

  # Creates aicache service.
  service "aicache" do
    supports :reload => true, :restart => true, :status => true, :start => true, :stop => true
    action :nothing
  end

  # (Re)generates the aicache config file.
  execute "/etc/aicache/aicache-cat.sh" do
    user "aicache"
    group "aicache"
    umask "0077"
    action :nothing
    notifies :reload, resources(:service => "aicache")
  end

  # Deletes the individual server file and notifies the concatenation script if necessary.
  file ::File.join("/etc/aicache/#{node[:lb][:service][:provider]}.d", pool_name, backend_id) do
    action :delete
    backup false
    notifies :run, resources(:execute => "/etc/aicache/aicache-cat.sh")
  end

end


action :detach_request do

  pool_name = new_resource.pool_name

  log "  Detach request for #{new_resource.backend_id} / #{pool_name}"

  # Runs remote_recipe for each vhost the app server is part of.
  # See http://support.rightscale.com/12-Guides/Chef_Cookbooks_Developer_Guide/Chef_Resources#RemoteRecipe for the "remote_recipe" resource.
  remote_recipe "Detach me from load balancer" do
    recipe "lb::handle_detach"
    attributes :remote_recipe => {
      :backend_id => new_resource.backend_id,
      :pools => pool_name
    }
    recipients_tags "loadbalancer:#{pool_name}=lb"
  end

end


action :setup_monitoring do

  log "  Setup monitoring for aicache"

  # Installs the aicache collectd script into the collectd library plugins directory.
  cookbook_file "/usr/local/aicache/collectd_plugin.sh" do
    owner "root"
    group "root"
    mode "0755"
    source "aicache_collectd.sh"
    cookbook "lb_aicache"
  end

  # Adds a collectd config file for the aiCache collectd script with the exec plugin and restart collectd if necessary.
  template ::File.join(node[:rightscale][:collectd_plugin_dir], "aicache.conf") do
    backup false
    source "aicache_collectd.conf.erb"
    notifies :restart, resources(:service => "collectd")
    cookbook "lb_aicache"
  end

 # Adds monitor file for aiCache monitoring
  cookbook_file "/usr/local/aicache/monitor" do
    owner "aicache"
    group "aicache"
    mode "0755"
    source "aicache_monitor_exe"
    cookbook "lb_aicache"
  end
 # Creates cron to run the monitoring file from above
  cron "monitoring" do
    minute "*/5"
    command "cd /usr/local/aicache/;./monitor"
  end

end


action :restart do

  log "  Restarting aicache"

  require 'timeout'

  Timeout::timeout(new_resource.timeout) do
    while true
      `service #{new_resource.name} stop`
      break if `service #{new_resource.name} status` !~ /is running/
      Chef::Log.info "service #{new_resource.name} not stopped; retrying in 5 seconds"
      sleep 5
    end

    while true
      `service #{new_resource.name} start`
      break if `service #{new_resource.name} status` =~ /is running/
      Chef::Log.info "service #{new_resource.name} not started; retrying in 5 seconds"
      sleep 5
    end
  end

end
