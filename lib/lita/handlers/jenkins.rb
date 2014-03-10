require 'json'
require 'base64'

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

      route /j(?:enkins)? b (\d+)/i, :jenkins_build_by_id, command: true, help: {
        'jekins b <job_id>' => 'builds the job specified by job_id. List jobs to get ID.'
      }

      def jenkins_build_by_id(response)
        job = jobs[response.matches.last.last.to_i - 1]

        if job
          jenkins_build(response, job['name'])
        else
          response.reply "I couldn't find that job. Try `jenkins list` to get a list."
        end
      end

      def jenkins_build(response, job_name=nil)
        url    = Lita.config.handlers.jenkins.url
        auth64 = Base64.encode64(Lita.config.handlers.jenkins.auth)
        path   = "#{url}/job/#{job_name}/build"

        http_resp = http.post(path) do |req|
          req.headers['Authorization'] = "Basic #{auth64}"
        end

        if http_resp.status == 201
          response.reply "(#{http_resp.status}) Build started for #{job_name} #{url}/job/#{job_name}"
        else
          response.reply http_resp.body
        end
      end

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
        self.class.jobs = jobs if self.class.jobs.empty?
      end
    end

    Lita.register_handler(Jenkins)
  end
end
