module RimeDeploy
  module Upgrade
    class UpgradeRimeAutoDeployJob < Job
      def call
        puts "Upgrade `Rime Auto Deploy` script ..."
        project_path = File.expand_path("..", __dir__)
        if File.directory?(File.join(project_path, ".git"))
          puts "Git repository found."
          puts "Try upgrading..."
          upgrade_repository(project_path)
        else
          puts "You can download the latest version from here."
          puts "https://github.com/Mark24Code/rime-auto-deploy"
        end
        return :next
      end
    end

    class UpgradeRimeConfigJob < Job
      def call
        puts "Upgrade Rime Config"
        config_abs_path = File.expand_path(Store.config_path)
        if File.directory?(File.join(config_abs_path, ".git"))
          puts "Git repository found."
          puts "Try upgrading..."
          upgrade_repository(config_abs_path)
        else
          raise RimeDeployError, "Rime directory is not a Git checkout. Keep your data and back it up before migrating: #{config_abs_path}"
        end

        return :next
      end
    end
  end
end
