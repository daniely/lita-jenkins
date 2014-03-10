require 'json'

module Lita
  module Handlers
    class Jenkins < Handler
      class << self
        attr_accessor :jobs
      end

      def self.default_config(config)
        config.url = nil
        self.jobs = {}
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

          reply << format_job(i, state, job_name) if filter_match(filter, text_to_check)
        end

        cache_job_list(parsed_response['jobs'])

        response.reply reply
      end

      def jobs
        self.class.jobs
      end

      private

      def format_job(i, state, job_name)
        "[#{i+1}] #{state} #{job_name}\n"
      end

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

      def cache_job_list(jobs)
        self.class.jobs ||= jobs
      end
    end

    Lita.register_handler(Jenkins)
  end
end
