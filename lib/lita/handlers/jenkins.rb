require 'json'
require 'base64'

module Lita
  module Handlers
    class Jenkins < Handler

      config :auth
      config :url

      route /j(?:enkins)? list( (.+))?/i, :jenkins_list, command: true, help: {
        'jenkins list <filter>' => 'lists Jenkins jobs'
      }

      route /j(?:enkins)? b(?:uild)? ([\w\.\-_ ]+)/i, :jenkins_build, command: true, help: {
        'jenkins b(uild) <job_id or job_name>' => 'builds the job specified by ID or name. List jobs to get ID.'
      }

      def jenkins_build(response)
        job = find_job(response.matches.last.last)

        if job
          url    = config.url
          path   = "#{url}/job/#{job['name']}/build"

          http_resp = http.post(path) do |req|
            req.headers = headers
          end

          if http_resp.status == 201
            response.reply "(#{http_resp.status}) Build started for #{job['name']} #{url}/job/#{job['name']}"
          else
            response.reply http_resp.body
          end
        else
          response.reply "I couldn't find that job. Try `jenkins list` to get a list."
        end
      end

      def jenkins_list(response)
        filter = response.matches.first.last
        reply  = ''

        jobs.each_with_index do |job, i|
          job_name      = job['name']
          state         = color_to_state(job['color'])
          text_to_check = state + job_name

          reply << format_job(i, state, job_name) if filter_match(filter, text_to_check)
        end

        response.reply reply
      end

      def headers
        {}.tap do |headers|
          headers["Authorization"] = "Basic #{Base64.encode64(config.auth).chomp}" if config.auth
        end
      end

      def jobs
        api_response = http.get(api_url) do |req|
          req.headers = headers
        end
        JSON.parse(api_response.body)["jobs"]
      end

      private

      def api_url
        "#{config.url}/api/json"
      end

      def find_job(requested_job)
        # Determine if job is only a number.
        if requested_job.match(/\A[-+]?\d+\z/)
          jobs[requested_job.to_i - 1]
        else
          jobs.select { |j| j['name'] == requested_job }.last
        end
      end

      def format_job(i, state, job_name)
        "[#{i + 1}] #{state} #{job_name}\n"
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
    end

    Lita.register_handler(Jenkins)
  end
end
