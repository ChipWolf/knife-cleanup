#
# Author:: Marius Ducea (<marius.ducea@gmail.com>)
# Copyright:: Copyright (c) 2013 Marius Ducea
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module ServerCleanup
  class CleanupVersions < Chef::Knife

    deps do
      require 'fileutils'
      require 'chef/api_client'
      require 'chef/cookbook_loader'
      require 'chef/knife/cookbook_download'
    end

    banner "knife cleanup versions (options)"

    option :delete,
     :short => "-D",
     :long => "--delete",
     :description => "Delete the unused versions of the cookbooks",
     :boolean => true

    option :backup,
     :short => "-B",
     :long => "--backup",
     :description => "Backup the cookbook versions that are being deleted",
     :boolean => true,
     :default => false

    option :keep,
     :short => "-K",
     :long => "--keep N",
     :description => "Keep the last N versions. Default is 3.",
     :default => 3

     option :cookbook,
      :short => "-C COOKBOOK",
      :long => "--cookbook COOKBOOK",
      :description => "Only cleanup the named cookbook"

     option :runlist,
      :short => "-R",
      :long => "--runlist RUNLIST",
      :description => "Runlist for evaluation, e.g. 'cookbook::default'",
      :default => false

    def run
      cookbooks
    end

    def cookbooks
      ui.msg "Searching for unused cookbook versions..."
      endpoint = "/cookbooks"
      endpoint += "/#{config[:cookbook]}" unless config[:cookbook].nil?
      all_cookbooks = rest.get_rest("#{endpoint}?num_versions=all")
      latest_cookbooks = rest.get_rest("#{endpoint}?num_versions=#{config[:keep]}")

      # All cookbooks eligible for deletion
      cbv = all_cookbooks.inject({}) do |collected, ( cookbook, versions )|
        collected[cookbook] = versions["versions"].map {|v| v['version']}
        collected
      end

      # Get latest cookbooks
      latest = latest_cookbooks.inject({}) do |collected, ( cookbook, versions )|
        collected[cookbook] = versions["versions"].map {|v| v['version']}
        collected
      end

      # Purge latest cookbooks from candidate list
      latest.each_key do |cb|
        latest[cb].each do |v|
          cbv[cb].delete(v)
        end
      end

      # Purge versions used with runlist for env 
      Chef::Environment.list.each_key do |env_list|
        if config[:runlist]
          keep_for_runlist(cbv, env_list, config[:runlist], latest)
        end
        keep_for_pinned(cbv, env_list, latest)
      end

      confirm("Do you really want to delete unused cookbook versions from the server")  if config[:delete]
      ui.msg "Cookbook Versions:"
      key_length = cbv.empty? ? 0 : cbv.keys.map {|name| name.size }.max + 2
      cbv.each_key do |cb|
        next if cbv[cb].empty?
        print "  "
        printf "  %2d ", cbv[cb].length if config[:verbosity]
        print "#{cb.ljust(key_length)}"
        print "[keeping"
        latest[cb].each do |v|
          print " #{v}"
        end
        print "] "
        cbv[cb].each do |cb_ver|
          print "#{cb_ver} "
          if config[:delete]
            dir = ".cleanup/#{cb}/"
            backup_cookbook(cb,cb_ver,dir) if config[:backup]
            delete_cookbook(cb, cb_ver)
          end
        end
        print "\n"
      end

      if !config[:delete]
        ui.msg "Not deleting unused cookbook versions; use --delete if you want to remove them"
      end
    end

    def keep_for_runlist(cb_versions, env_name, runlist, latest)
      runlist_req = { "run_list"  => [ runlist ] }
      begin
        run_cookbooks = \
          rest.post_rest("/environments/#{env_name}/cookbook_versions", runlist_req)
      rescue => e
        ui.msg " run_list invalid for env [#{env_name}]: #{e.message}\n" if config[:verbosity]
        return false
      end

      run_cookbooks.each_key do |cb|
        begin
          kept = cb_versions[run_cookbooks[cb].name].delete(run_cookbooks[cb].version)
        rescue
          "Skipping"
        end
        latest[cb].push(run_cookbooks[cb].version) if kept
        ui.msg \
         " keeping #{run_cookbooks[cb].name}:#{run_cookbooks[cb].version} for runlist env [#{env_name}]\n" \
           if (kept and config[:verbosity])
      end
      return true
    end

    def keep_for_pinned(cb_versions, env_name, latest)
      env = Chef::Environment.load(env_name)

      return false unless !env.cookbook_versions.empty?
      env.cookbook_versions.each_key do |cb|
        cb_ver = env.cookbook_versions[cb].split(" ").last
        begin
          kept = cb_versions[cb].delete(cb_ver)
        rescue
          "Skipping..."
        end
        latest[cb].push(cb_ver) if kept
        ui.msg \
          " keeping #{cb}:#{cb_ver} for pinned env [#{env_name}]\n" \
            if (kept and config[:verbosity])
      end
      return true
    end

    def delete_cookbook(cb, cb_ver)
      ui.msg "Deleting cookbook #{cb}@#{cb_ver}"
      rest.delete_rest("cookbooks/#{cb}/#{cb_ver}")
      print ". "
    end

    def backup_cookbook(cb,cb_ver,dir)
      ui.msg "\nBacking up cookbook #{cb}@#{cb_ver}"
      FileUtils.mkdir_p(dir)
      dld = Chef::Knife::CookbookDownload.new
      dld.name_args = [cb, cb_ver]
      dld.config[:download_directory] = dir
      dld.config[:force] = true
      begin
        dld.run
      rescue
        ui.msg "Failed to download cookbook #{cb}@#{cb_ver}, skipping"
        FileUtils.rm_r(File.join(dir, cb + "-" + cb_ver))
      end
    end
  end
end
