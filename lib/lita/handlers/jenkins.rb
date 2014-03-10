require 'json'

module Lita
  module Handlers
    class Jenkins < Handler
      def self.default_config(config)
        config.url = nil
      end

      route /j(?:enkins)? list( (.+))?/i, :jenkins_list, command: true, help: {
        'jekins list <filter>' => 'lists Jenkins jobs'
      }

      def jenkins_list(response)
        url             = Lita.config.handlers.jenkins.url
        path            = "#{url}/api/json"
        filter          = response.matches.first.last

        api_response    = http.get(path)
        parsed_response = JSON.parse(api_response.body)
        reply = ''

        parsed_response['jobs'].each_with_index do |job, i|
          job_name      = job['name']
          state         = color_to_state(job['color'])
          text_to_check = state + job_name

          reply << "[#{i+1}] #{state} #{job_name}\n" if filter_match(filter, text_to_check)
        end

        response.reply reply
      end

      private

      def color_to_state(text)
        case text
        when /disabled/
          'DISA'
        when /red/
          'FAIL'
        else
          'SUCC'
        end
      end

      def filter_match(filter, text)
        text.match(/#{filter}/i)
      end
    end

    Lita.register_handler(Jenkins)
  end
end
