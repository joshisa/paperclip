module Paperclip
  module Storage
    # fog is a modern and versatile cloud computing library for Ruby.
    # Among others, fog-softlayer supports Softlayer ObjectStorage to store your files.
    # * +fog_credentials+: Takes a Hash with your credentials. For softlayer,
    #   you can use the following format:
    #     bluemix_objstor_username: '<your bluemix object storage VCAP username>'
    #     bluemix_objstor_password: '<your bluemix object storage VCAP password>'
    #     provider: 'Softlayer'
    #     bluemix_objstor_user: '<your bluemix appname>'
    #     bluemix_objstor_auth_url: '<your bluemix object storage VCAP auth_url>'
    # * +fog_directory+: This is the name of the Bluemix Object Storage Container that will
    #   store your files.  Remember that the container must be unique across
    #   the give user's account. If the container does not exist, Paperclip will
    #   attempt to create it.
    # * +fog_public+: (optional, defaults to true) Should the uploaded
    #   files be public or not? (true/false)
    # * +fog_host+: (optional) The fully-qualified domain name (FQDN)
    #   that is the alias to the Object Storage domain of your container, e.g.
    #   'https://dal05.objectstorage.softlayer.net:443/'.

    module Softlayer
      def self.extended base
        begin
          puts "Entering the softlayer paperclip zone ..."
          require 'fog-softlayer'
        rescue LoadError => e
          e.message << " (You may need to install the fog-softlayer gem)"
          raise e
        end unless defined?(Fog)

        base.instance_eval do
          unless @options[:url].to_s.match(/\A:fog.*url\Z/)
            @options[:path]  = @options[:path].gsub(/:url/, @options[:url]).gsub(/\A:rails_root\/public\/system\//, '')
            @options[:url]   = ':fog_public_url'
          end
          Paperclip.interpolates(:fog_public_url) do |attachment, style|
            attachment.public_url(style)
          end unless Paperclip::Interpolations.respond_to? :fog_public_url
        end
      end

      def exists?(style = default_style)
        if original_filename
          !!directory.files.head(path(style))
        else
          false
        end
      end

      def fog_credentials
        @fog_credentials ||= parse_credentials(@options[:fog_credentials])
      end

      def fog_file
        @fog_file ||= begin
          value = @options[:fog_file]
          if !value
            {}
          elsif value.respond_to?(:call)
            value.call(self)
          else
            value
          end
        end
      end

      def fog_public(style = default_style)
        if @options.has_key?(:fog_public)
          if @options[:fog_public].respond_to?(:has_key?) && @options[:fog_public].has_key?(style)
            @options[:fog_public][style]
          else
            @options[:fog_public]
          end
        else
          true
        end
      end

      def flush_writes
        for style, file in @queued_for_write do
          log("saving #{path(style)}")
          retried = false
          begin
            directory.files.create(fog_file.merge(
              :body         => file,
              :key          => path(style),
              :public       => fog_public(style),
              :content_type => file.content_type
            ))
          rescue Excon::Errors::NotFound
            raise if retried
            retried = true
            directory.save
            retry
          ensure
            file.rewind
          end
        end

        after_flush_writes # allows attachment to clean up temp files

        @queued_for_write = {}
      end

      def flush_deletes
        for path in @queued_for_delete do
          log("deleting #{path}")
          directory.files.new(:key => path).destroy
        end
        @queued_for_delete = []
      end

      def public_url(style = default_style)
        if @options[:fog_host]
          "#{dynamic_fog_host_for_style(style)}/#{path(style)}"
        else
          if fog_credentials[:provider] == 'softlayer'
            puts "#{scheme}://#{host_name_for_directory}/#{path(style)}"
            "#{scheme}://#{host_name_for_directory}/#{path(style)}"
          else
            directory.files.new(:key => path(style)).public_url
          end
        end
      end

      def expiring_url(time = (Time.now + 3600), style_name = default_style)
        time = convert_time(time)
        http_url_method = "get_#{scheme}_url"
        if path(style_name) && directory.files.respond_to?(http_url_method)
          expiring_url = directory.files.public_send(http_url_method, path(style_name), time)

          if @options[:fog_host]
            expiring_url.gsub!(/#{host_name_for_directory}/, dynamic_fog_host_for_style(style_name))
          end
        else
          expiring_url = url(style_name)
        end

        return expiring_url
      end

      def parse_credentials(creds)
        creds = find_credentials(creds).stringify_keys
        (creds[RailsEnvironment.get] || creds).symbolize_keys
      end

      def copy_to_local_file(style, local_dest_path)
        log("copying #{path(style)} to local file #{local_dest_path}")
        ::File.open(local_dest_path, 'wb') do |local_file|
          file = directory.files.get(path(style))
          local_file.write(file.body)
        end
      rescue ::Fog::Errors::Error => e
        warn("#{e} - cannot copy #{path(style)} to local file #{local_dest_path}")
        false
      end

      private

      def convert_time(time)
        if time.is_a?(Fixnum)
          time = Time.now + time
        end
        time
      end

      def dynamic_fog_host_for_style(style)
        if @options[:fog_host].respond_to?(:call)
          @options[:fog_host].call(self)
        else
          (@options[:fog_host] =~ /%d/) ? @options[:fog_host] % (path(style).hash % 4) : @options[:fog_host]
        end
      end

      def host_name_for_directory
          "#{@options[:fog_host]}"
      end

      def find_credentials(creds)
        case creds
        when File
          YAML::load(ERB.new(File.read(creds.path)).result)
        when String, Pathname
          YAML::load(ERB.new(File.read(creds)).result)
        when Hash
          creds
        else
          if creds.respond_to?(:call)
            creds.call(self)
          else
            raise ArgumentError, "Credentials are not a path, file, hash or proc."
          end
        end
      end

      def connection
        @connection ||= ::Fog::Storage.new(fog_credentials)
      end

      def directory
        dir = if @options[:fog_directory].respond_to?(:call)
          @options[:fog_directory].call(self)
        else
          @options[:fog_directory]
        end

        @directory ||= connection.directories.new(:key => dir)
      end

      def scheme
        @scheme ||= fog_credentials[:scheme] || 'https'
      end
    end
  end
end
