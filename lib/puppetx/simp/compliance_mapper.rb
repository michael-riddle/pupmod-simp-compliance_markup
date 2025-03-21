# This is the shared codebase for the compliance_markup hiera
# backend. Each calling object (either the hiera backend class
# or the puppet lookup function) uses instance_eval to add these
# functions to the object.
#
# Then the object can call enforcement like so:
# enforcement('key::name') do |key, default|
#   lookup(key, { "default_value" => default})
# end
#
# The block is used to abstract lookup()
#
# This block will also return a KeyError if there is no key found, which must be
# trapped and converted into the correct response for the api. either throw :no_such_key
# or context.not_found()
#
# We also expect a small api in the object that includes these functions:
#
# debug(message)
# cached(key)
# cache(key, value)
# cache_has_key(key)
#
# which allow for debug logging, and caching, respectively.
require 'deep_merge'

def enforcement(key, context=self, options={"mode" => "value"}, &block)

  options['mode'] ||= 'value'

  # Throw away keys we know we can't handle.
  # This also prevents recursion.
  throw :no_such_key if
    key.match?(%r{^compliance_markup::(?!debug::)}) || (
      [
      'lookup_options',
      'compliance_map'
      ].include?(key)
    )

  retval = :notfound

  lock = context.cached_value('_simp_compliance_markup_lock') if context.cache_has_key('_simp_compliance_markup_lock')

  unless lock
    context.cache('_simp_compliance_markup_lock', true)

    begin
      profile_list = Array(call_function('lookup', 'compliance_markup::enforcement', { 'default_value' => [] }))

      unless profile_list == []
        debug("debug: compliance_markup::enforcement set to #{profile_list}, attempting to enforce")

        profile = profile_list.hash.to_s

        if context.cache_has_key("compliance_map_#{profile}")
          # If we have a cache for this profile, we've already found
          # everything that we're going to find.
          if context.cache_has_key(key)
            return context.cached_value(key)
          else
            throw :no_such_key
          end
        end

        debug("debug: compliance map for #{profile_list} not found, starting compiler")

        compile_start_time = Time.now
        profile_compiler   = compiler_class.new(self)

        profile_compiler.load(options, &block)

        case key
        when 'compliance_markup::debug::profiles'
          return profile_compiler.profile.keys
        when 'compliance_markup::debug::compliance_data'
          return {
            'version'  => '2.0.0',
            'profiles' => profile_compiler.profile,
            'ce'       => profile_compiler.ce,
            'checks'   => profile_compiler.check,
          }
        end

        profile_map = profile_compiler.list_puppet_params(profile_list).cook do |item|
          item[options["mode"]]

          # Add this parameter to the context cache so that it is
          # preserved between calls.
          #
          # This allows us to prevent deep recursion and repeated digging
          # into files with no benefit.
          context.cache(item["parameter"], item["value"])
        end

        context.cache("compliance_map_#{profile}", profile_map)

        compile_end_time = Time.now

        profile_map["compliance_markup::debug::hiera_backend_compile_time"] = (compile_end_time - compile_start_time)
        context.cache("compliance_map_#{profile}", profile_map)
        debug("debug: compiled compliance_map containing #{profile_map.size} keys in #{compile_end_time - compile_start_time} seconds")

        if key == "compliance_markup::debug::dump"
           retval = profile_map
        else
          # Handle a knockout prefix
          unless profile_map.key?("--" + key)
            if profile_map.key?(key)
              retval = profile_map[key]
            end
          end
        end

        # XXX ToDo: Generate a lookup_options hash, set to 'first', if the user specifies some
        # option that toggles it on. This would allow un-overridable enforcement at the hiera
        # layer (though it can still be overridden by resource-style class definitions)
      end
    rescue => e
      # noop
      warn e.message
      debug(e.message)
      debug(e.backtrace.inspect)
    ensure
      context.cache('_simp_compliance_markup_lock', false)
    end
  end

  throw :no_such_key if retval == :notfound

  retval
end

def compiler_class()
  Class.new do
    attr_reader :compliance_data
    attr_reader :callback
    attr_reader :version
    attr_accessor :v2

    def initialize(object)
      require 'semantic_puppet'

      @callback = object

      @version = SemanticPuppet::Version.parse('2.5.0')
    end

    def load(options={}, &block)
      @callback.debug("callback = #{callback.codebase}")

      module_scope_compliance_map = block.call 'compliance_markup::compliance_map', {}
      top_scope_compliance_map    = block.call 'compliance_map', {}

      @compliance_data = {}

      moduleroot = File.expand_path('../../../../../', __FILE__)
      rootpaths  = {}

      begin
        environmentroot            = "#{Puppet[:environmentpath]}/#{callback.environment}"
        env                        = Puppet::Settings::EnvironmentConf.load_from(environmentroot, ["/test"])
        rmodules                   = env.modulepath.split(":")
        rootpaths[environmentroot] = true
      rescue StandardError => ex
        callback.debug(ex)

        rmodules = []
      end
      modpaths  = rmodules + [moduleroot]
      modpaths2 = []

      modpaths.each do |modpath|
        if modpath == "$basemodulepath"
          modpaths2 = modpaths2 + Puppet[:basemodulepath].split(":")
        else
          modpaths2 = modpaths2 + [modpath]
        end
      end
      modpaths2.each do |modpath|
        begin
          Dir.glob("#{modpath}/*") do |modulename|
            begin
              rootpaths[modulename] = true
            rescue
            end
          end
        rescue
        end
      end

      base_paths = rootpaths.keys

      override_data_dirs = ENV.fetch('HIERA_compliance_data_dir', options[:data_dirs])
      override_data_dirs = Array(override_data_dirs) if override_data_dirs.is_a?(String)

      base_paths = override_data_dirs if override_data_dirs.is_a?(Array)
      base_paths += options[:aux_paths] if (options[:aux_paths] && options[:aux_paths].is_a?(Array))

      load_paths = [
        "SIMP/compliance_profiles",
        "simp/compliance_profiles"
      ]

      ['yaml', 'json'].each do |type|
        # Using the power of glob for great good
        Dir.glob(
          File.join(
            "{#{base_paths.join(',')}}",   # Glob against all base module paths
              "{#{load_paths.join(',')}}", # And all intermediate load paths
              '**',                        # And all directories underneath
              "*.#{type}"                  # Of the given file type
          )
        ) do |filename|
          begin
            @compliance_data[filename] = YAML.load(File.read(filename)) if (type == 'yaml')
            @compliance_data[filename] = JSON.parse(File.read(filename)) if (type == 'json')
          rescue => e
            warn(%{compliance_engine: Invalid '#{type}' file found at '#{filename}' => #{e}})
          end
        end
      end

      @compliance_data["puppet://compliance_markup::compliance_map"] = (module_scope_compliance_map)
      @compliance_data["puppet://compliance_map"]                    = (top_scope_compliance_map)

      @v2 = v2_compiler.new(callback)

      @compliance_data.each do |filename, map|
        if map.key?("version")
          version = SemanticPuppet::Version.parse(map["version"])

          if version.major == 2
            v2.import(filename, map)
          end
        end
      end
    end

    def ce
      v2.ce
    end

    def control
      v2.control
    end

    def check
      v2.check
    end

    def profile
      v2.profile
    end

    def v2_compiler()
      Class.new do
        def initialize(callback)
          @control_list = {}
          @configuration_element_list = {}
          @check_list = {}
          @profile_list = {}
          @data_locations = {
              "ce" => {},
              "profiles" => {},
              "controls" => {},
              "checks" => {},
          }
          @callback = callback
        end
        def callback
          @callback
        end
        def ce
          @configuration_element_list
        end

        def control
          @control_list
        end

        def check
          @check_list
        end

        def profile
          @profile_list
        end

        def fact_match(fact_value, confinement_value)
          def string_match(fact_value, confinement_value)
            return fact_value != confinement_value.delete_prefix('!') if confinement_value.start_with?('!')

            fact_value == confinement_value
          end

          case confinement_value.class.to_s
          when 'Array'
            return confinement_value.any? do |value|
              if value.is_a?(Array)
                fact_value == value
              else
                fact_match(fact_value, value)
              end
            end
          when 'String'
            return string_match(fact_value, confinement_value)
          else
            return fact_value == confinement_value
          end
        end

        def apply_confinement(value)
          value.delete_if do |_key, specification|
            delete_item = false

            catch(:confine_end) do
              if specification.key?('confine')
                confine = specification['confine']

                if confine
                  unless confine.is_a?(Hash)

                    unless specification['settings'].key?('value')
                      location = 'unknown'

                      raise "'confine' must be a Hash in '#{location}'"
                    end
                  end

                  confine.each do |confinement_setting, confinement_value|
                    if confinement_setting == 'module_name'
                      known_module = @callback.module_list.select { |obj| obj['name'] == confinement_value }

                      if known_module.empty?
                        delete_item = true
                        throw :confine_end
                      end

                      if confine['module_version']
                        require 'semantic_puppet'

                        currentver = nil
                        requiredver = {}
                        begin
                          currentver = SemanticPuppet::Version.parse(known_module.first['version'])
                          requiredver = SemanticPuppet::VersionRange.parse(confine['module_version'])
                        rescue
                          warn "Unable to match #{known_module} against version requirement #{confine['module_version']}"
                          delete_item = true
                          throw :confine_end
                        end

                        unless requiredver.include?(currentver)
                          delete_item = true
                          throw :confine_end
                        end
                      end
                    end

                    fact_value = @callback.lookup_fact(confinement_setting)
                    next if fact_value.nil?
                    unless fact_match(fact_value, confinement_value)
                      delete_item = true
                      throw :confine_end
                    end
                  end
                end
              end
            end

            delete_item
          end

          value
        end

        def import(filename, data)
          data.each do |key, value|
            apply_confinement(value) if value.is_a?(Hash)

            case key
            when "profiles"
              value.each do |profile, map|
                @profile_list[profile] ||= {}
                @profile_list[profile] = @profile_list[profile].deep_merge!(map, {:knockout_prefix => '--'})
              end
            when "controls"
              value.each do |profile, map|
                @control_list[profile] ||= {}
                @control_list[profile] = @control_list[profile].deep_merge!(map, {:knockout_prefix => '--'})
              end
            when "checks"
              value.each do |profile, map|
                @check_list[profile] ||= {}
                @check_list[profile] = @check_list[profile].deep_merge!(map, {:knockout_prefix => '--'})
              end
            when "ce"
              value.each do |profile, map|
                @configuration_element_list[profile] ||= {}
                @configuration_element_list[profile] = @configuration_element_list[profile].deep_merge!(map, {:knockout_prefix => '--'})
              end
            end
          end
        end

        def check_map
          return @check_map unless @check_map.nil?

          @check_map = {
            'checks'   => {},
            'controls' => {},
            'ces'      => {},
          }

          @check_list.each do |check_name, specification|
            # Skip unless this item applies to puppet
            unless (specification['type'] == 'puppet') || (specification['type'] == 'puppet-class-parameter')
              @callback.debug("SKIP: '#{check_name}' is not a puppet parameter")
              next
            end

            # Skip unless we actually have a parameter setting
            unless specification.key?('settings')
              @callback.debug("SKIP: '#{check_name}' does not have any settings")
              next
            end

            unless specification['settings'].key?('parameter')
              @callback.debug("SKIP: '#{check_name}' does not have a parameter specified")
              next
            end

            # A parameter with a setting but without a value is invalid
            unless specification['settings'].key?('value')
              location = 'unknown'

              raise "'#{check_name}' has parameter '#{specification['settings']['parameter']}' in '#{location}' but has no assigned value"
            end

            @check_map['checks'][check_name] = [specification]

            specification['controls']&.each do |control_name, value|
              next unless value
              @check_map['controls'][control_name] = [] if @check_map['controls'][control_name].nil?
              @check_map['controls'][control_name] << specification
            end

            specification['ces']&.each do |ce_name|
              next unless @configuration_element_list.key?(ce_name)

              @check_map['ces'][ce_name] = [] if @check_map['ces'][ce_name].nil?
              @check_map['ces'][ce_name] << specification

              @configuration_element_list[ce_name]['controls']&.each do |control_name, value|
                next unless value

                @check_map['controls'][control_name] = [] if @check_map['controls'][control_name].nil?
                @check_map['controls'][control_name] << specification
              end
            end
          end

          @check_map
        end

        def list_puppet_params(profile_list)
          specifications = []

          profile_list.reverse.each do |profile_name|
            unless @profile_list.key?(profile_name)
              @callback.debug(%{SKIP: Profile '#{profile_name}' not in '#{@profile_list.keys.join("', '")}'})
              next
            end

            info = @profile_list[profile_name]

            ['checks', 'controls', 'ces'].each do |map_type|
              info[map_type]&.each do |key, value|
                next unless value
                next if check_map[map_type][key].nil?
                specifications += check_map[map_type][key]
              end
            end
          end

          # If we didn't find anything, we can just bail
          return {} if specifications.empty?

          if specifications.count > 1
            parameters = specifications.map { |specification| specification['settings']['parameter'] }
            parameters.uniq.each do |param|
              if parameters.count { |p| p == param } > 1
                @callback.debug("WARN: Multiple valid specifications found for #{param}, they will be merged in the order that they were defined")
              end
            end
          end

          retval = {}
          specifications.each do |specification|
            parameter = specification['settings']['parameter']

            unless retval.key?(parameter)
              retval[parameter] = {
                'parameter'   => parameter.dup,
                'value'       => Marshal.load(Marshal.dump(specification['settings']['value'])),
                'controls'    => specification['controls'].nil? ? {} : Marshal.load(Marshal.dump(specification['controls'])),
                'identifiers' => specification['identifiers'].nil? ? {} : Marshal.load(Marshal.dump(specification['identifiers'])),
                'oval-ids'    => specification['oval-ids'].nil? ? {} : Marshal.load(Marshal.dump(specification['oval-ids'])),
              }

              next
            end

            # Merge
            # XXX ToDo: Need merge settings support
            begin
              case retval[parameter]['value'].class.to_s
              when 'Array'
                retval[parameter]['value'] = (retval[parameter]['value'] + Marshal.load(Marshal.dump(specification['settings']['value']))).uniq
              when 'Hash'
                retval[parameter]['value'] = retval[parameter]['value'].deep_merge!(specification['settings']['value'])
              else
                retval[parameter]['value'] = Marshal.load(Marshal.dump(specification['settings']['value']))
              end
            rescue
              if retval[parameter]['value'].class.to_s != specification['settings']['value'].class.to_s
                raise "Value type mismatch for #{parameter}"
              else
                raise "Merge failed for values in #{parameter}"
              end
            end

            ['controls', 'identifiers', 'oval-ids'].each do |key|
              next if specification[key].nil?
              begin
                case retval[parameter][key].class.to_s
                when 'Array'
                  retval[parameter][key] = (retval[parameter][key] + Marshal.load(Marshal.dump(specification[key]))).uniq
                when 'Hash'
                  retval[parameter][key] = retval[parameter][key].deep_merge!(specification[key])
                else
                  retval[parameter][key] = Marshal.load(Marshal.dump(specification[key]))
                end
              rescue
                if retval[parameter][key].class.to_s != specification[key].class.to_s
                  raise "Type mismatch for #{key} in #{parameter}"
                else
                  raise "Merge failed for #{key} in #{parameter}"
                end
              end
            end
          end

          return retval
        end # list_puppet_params()
      end # Class.new
    end # v2_compiler()

    def control_list()
      Class.new do
        include Enumerable

        def initialize(hash)
          @hash = hash
        end

        def [](key)
          @hash[key]
        end

        def each(&block)
          @hash.each(&block)
        end

        def cook(&block)
          nhash = {}
          @hash.each do |key, value|
            nvalue = yield value
            nhash[key] = nvalue
          end
          nhash
        end

        def to_json()
          @hash.to_json
        end

        def to_yaml()
          @hash.to_yaml
        end

        def to_h()
          @hash
        end
      end
    end

    def list_puppet_params(profile_list)
      control_list.new(v2.list_puppet_params(profile_list))
    end
  end
end
