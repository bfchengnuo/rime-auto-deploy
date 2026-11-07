#!/usr/bin/env ruby

require_relative "lib/core"
require_relative "lib/config"
require_relative "share/upgrade"
require_relative "share/personal_data"

module OSPatch
  def check_os
    case RUBY_PLATFORM.downcase
    when /darwin/
      @osname = "MacOS"
    when /linux/
      @osname = "LinuxDistro"
    when /mswin|win32|mingw|cygwin/
      @osname = "Windows"
    else
      not_support_exit
    end
  end
end
module RimeDeploy
  class Installer
    include OSPatch
    def initialize
      @osname = nil
      check_os
      run
    end

    def not_support_exit
      puts "Not support this system. Bye~"
      exit 0
    end

    def run
      require_relative "os/#{@osname}"
      instance_eval("#{@osname}JobGroup.new.call")
    end
  end
end

RimeDeploy::Installer.new
