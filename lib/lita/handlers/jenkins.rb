require 'jenkins_api_client'

module Lita
  module Handlers
    class Jenkins < Handler

      namespace "jenkins"

      config :server, required: true
      config :org_domain, required: true

      route /j(?:enkins)? a(?:uth)? (check|set|del)_token( (.+))?/i, :auth, command: true, help: {
        'j(enkins) a(uth) {check|set|del}_token' => 'Check, set or delete your token for playing with Jenkins'
      }

      route /j(?:enkins)? list( (.+))?/i, :list, command: true, help: {
        'jenkins list' => 'Shows all accessable Jenkins jobs with last status'
      }

      route /j(?:enkins)? show( (.+))?/i, :show, command: true, help: {
        'jenkins show <job_name>' => 'Shows info for <job_name> job'
      }

      route /j(?:enkins)? b(?:uild)? (\w+)( (.+))?/i, :build, command: true, help: {
        'jenkins b(uild) <job_name> param:value,param2:value2' => 'Builds the job specified by name'
      }

      def build(response)
        log.info response.matches
        job_name   = response.matches.last.first
        job_params = {}
        opts       = { 'build_start_timeout': 30 }

        unless response.matches.last.last.nil?
          raw_params = response.matches.last.last

          raw_params.split(',').each do |pair|
            key, value = pair.split(':')
            job_params[key] = value
          end
        end

        client = make_client(response.user.mention_name)

        if client
          begin
            client.job.build(job_name, job_params, opts)
            last = client.job.get_builds(job_name).first
            response.reply "Build started for #{job_name} - <#{last['url']}console>"
          rescue
            response.reply "Build failed, maybe job parametrized?"
          end
        else
          "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      def auth(response)
        username = response.user.mention_name
        mode     = response.matches.last.first

        reply = case mode
        when 'check'
          user_token = redis.get(username)
          if user_token.nil?
            'Token not found, you need set token via "lita jenkins auth set_token <token>" command'
          else
            'Token already set, you can play with Jenkins'
          end
        when 'set'
          user_token = response.matches.last.last.strip

          if redis.set(username, user_token)
            'Token saved, enjoy!'
          else
            'We have some troubles, try later'
          end
        when 'del'
          user_token = redis.get(username)

          if redis.del(username)
            'Token deleted, so far so good'
          else
            'We have some troubles, try later'
          end
        else
          'Wrong command for "jenkins auth"'
        end

        response.reply reply
      end

      def show(response)
        client = make_client(response.user.mention_name)
        filter = response.matches.first.last

        if client
          job = client.job.list_details(filter)
          response.reply "General: <#{job['url']}|#{job['name']}> - #{job['color']}
Desc: #{job['description']}
Health: #{job['healthReport'][0]['score']} - #{job['healthReport'][0]['description']}
Last build: <#{job['lastBuild']['url']}>"
        else
          response.reply "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      def list(response)
        client = make_client(response.user.mention_name)
        if client
          answer = ''
          jobs = client.job.list_all_with_details
          jobs.each_with_index do |job, n|
            answer << "#{n + 1}. <#{job['url']}|#{job['name']}> - #{job['color']}\n"
          end
          response.reply answer
        else
          response.reply "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      private

      def make_client(username)
        user_token = redis.get(username)

        if user_token.nil?
          false
        else
          log.info "#{username} | #{config.org_domain} | #{user_token} | #{config.server}"
          JenkinsApi::Client.new(
            server_ip: config.server,
            server_port: '443',
            username: "#{username}@#{config.org_domain}",
            password: user_token,
            ssl: true
          )
        end
      end
    end

    Lita.register_handler(Jenkins)
  end
end
