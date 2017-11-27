require 'jenkins_api_client'
require 'json'
require 'http'
require 'uri'

module Lita
  module Handlers
    class Jenkins < Handler

      namespace 'jenkins'

      config :server, required: true
      config :org_domain, required: true
      config :notify_user, required: true

      route /j(?:enkins)? a(?:uth)? (check|set|del)_token( (.+))?/i, :auth, command: true, help: {
        'j(enkins) a(uth) {check|set|del}_token' => 'Check, set or delete your token for playing with Jenkins'
      }

      route /j(?:enkins)?(\W+)?n(?:otify)?(\W+)?(\w+)?$?/i, :set_notify_mode, command: true, help: {
        'j(enkins) n(notify) {true|false}' => 'Set notify mode for build status: false - no notify (default), true - notify to direct messages'
      }

      route /j(?:enkins)? list( (.+))?/i, :list, command: true, help: {
        'jenkins list' => 'Shows all accessable Jenkins jobs with last status'
      }

      route /j(?:enkins)? show( (.+))?/i, :show, command: true, help: {
        'jenkins show <job_name>' => 'Shows info for <job_name> job'
      }

      route /j(?:enkins)? b(?:uild)? ([\w\-]+)( (.+))?/i, :build, command: true, help: {
        'jenkins b(uild) <job_name> param:value,param2:value2' => 'Builds the job specified by name'
      }

      route /j(?:enkins)?(\W+)?d(?:eploy)?(\W+)?([\w\-\.]+)(\W+)?([\w\-\,]+)?(\W+)?to(\W+)?([\w\-]+)/i, :deploy, command: true, help: {
        'jenkins d(eploy) <branch> <project1,project2> to <stage>' => 'Start dynamic deploy with params. Не выбранный бренч, зальет версию продакшна.'
      }

      on :loaded, :loop

      def loop(response)
        every(10) do |timer|
          begin
            puts 'begin hash'
            hash = JSON.parse(redis.get('notify'))
          rescue Exception => e
            puts 'rescue hash'
            redis.set('notify', {}.to_json)
            hash = JSON.parse(redis.get('notify'))
          end
          puts 'client'
          client = make_client(config.notify_user)

          def process_job(hash, job_name, last_build, client)
            puts 'inside process_job'
            # if hash[jjob['name']] && hash[jjob['name']] < client.job.get_builds(jjob['name']).first['number']
            hash[job_name] += 1
            puts "/job/#{job_name}/#{hash[job_name]}/api/json"
            begin
              puts 'inside begin build'
              build = client.api_get_request("/job/#{job_name}/#{hash[job_name]}/api/json")
            rescue JenkinsApi::Exceptions::NotFound => e
              puts 'resuce begin build resdis set'
              redis.set('notify', hash.to_json)
              puts 'again run process_job'
              process_job(hash, job_name, last_build, client) if hash[job_name] < last_build
            end
            puts 'cause'
            cause = build['actions'].select { |e| e['_class'] == 'hudson.model.CauseAction' }
            puts 'user_cause'
            user_cause = cause.first['causes'].select { |e| e['_class'] == 'hudson.model.Cause$UserIdCause' }.first
            puts 'return if building'
            return if build['building']
            puts 'unless user_cause nil ?'
            unless user_cause.nil?
              puts 'inside unless user_cause nil ?'
              user         = user_cause['userId'].split('@').first
              puts 'runned'
              runned       = build['displayName']
              puts 'build_number'
              build_number = hash[job_name]
              puts 'started'
              started      = build['timestamp']
              puts 'duration'
              duration     = build['duration']
              puts 'result'
              result       = build['result']
              puts 'url'
              url          = build['url']

              puts 'unless notify mode'
              unless notify_mode = redis.get("#{user}:notify")
                puts 'inside unless notify mode'
                redis.set("#{user}:notify", 'false')
                puts 'set notify mode false'
                notify_mode = 'false'
              end

              puts 'if notify_mode true'
              if notify_mode == 'true'
                if result == 'SUCCESS'
                  puts 'if result success'
                  color = 'good'
                elsif result == 'FAILURE'
                  puts 'if result failure'
                  color = 'danger'
                else
                  puts 'else warning'
                  color = 'warning'
                end

                puts 'started / 1000'
                started    = started.to_i / 1000
                puts 'duration / 1000'
                duration   = duration.to_i / 1000
                puts 'time'
                time       = Time.at(started).strftime("%d-%m-%Y %H:%M:%S")
                puts 'text'
                text       = "Result for #{job_name} #{build_number} started on #{time} for #{runned} is #{result}\nDuration: #{duration} sec"
                puts 'attachment'
                attachment = Lita::Adapters::Slack::Attachment.new(
                  text, {
                    title: 'Build status',
                    title_link: url,
                    text: text,
                    color: color
                  }
                )
                puts 'lita_user'
                lita_user = Lita::User.find_by_mention_name(user)
                # target    = Source.new(user: lita_user)
                puts 'robot.send_attachment'
                puts text
                robot.chat_service.send_attachment(lita_user, attachment)
                # robot.send_message(target, text)
              end
              # puts "#{user} #{job_name} #{runned} #{build_number} #{started} #{duration} #{result} #{url}"
            end
            puts 'after unless notify mode'
            redis.set('notify', hash.to_json)
            puts 'process_job if hash[job_name] < last_build'
            process_job(hash, job_name, last_build, client) if hash[job_name] < last_build
          end

          puts 'list_all_with_details'
          client.job.list_all_with_details.each do |jjob|
            puts 'inside list_all_with_details'
            unless jjob['color'] == 'disabled' || jjob['color'] == 'notbuilt'
              puts 'inside unless'
              last_build = client.job.get_builds(jjob['name']).first['number']

              if hash[jjob['name']]
                puts 'if hash'
                if hash[jjob['name']] < last_build
                  puts 'if hash < last_build'
                  process_job(hash, jjob['name'], last_build, client)
                end
              else
                puts 'else if no hash'
                hash[jjob['name']] = last_build
                puts 'else if no hash redis set'
                redis.set('notify', hash.to_json)
              end
            end
          end
        end
      end

      def deploy(response)
        params     = response.matches.last.reject(&:blank?) #["OTT-123", "avia", "sandbox-15"]
        project    = params[1]
        branch     = ''
        stage      = ''
        job_name   = 'dynamic_deploy'
        job_params = {}
        opts       = { 'build_start_timeout': 30 }
        username   = response.user.mention_name


        if params.size == 3
          branch = params[0]
          stage  = params[2]
        elsif params.size == 2
          stage  = params[1]
        else
          response.reply 'Something wrong with params :fire:'
          return
        end

        job_params = {
          'STAGE' => stage,
          'CHECKMASTER' => false,
          'PROJECTS' => {}
        }

        project.split(',').each do |proj|
          job_params['PROJECTS'][proj.upcase] = {
            'ENABLE' => true,
            'BRANCH' => branch
          }
        end

        client = make_client(username)

        if client
          begin

            user_full = "#{username}@#{config.org_domain}"
            token    = redis.get("#{username}:token")
            reply_text = ''

            path = "https://#{config.server}/job/dynamic_deploy/build"
            data = {
              'json' => {
                'parameter' => [
                  {
                    'name' => 'DEPLOY',
                    'value' => job_params.to_json
                  }
                ]
              }
            }
            encoded = URI.encode_www_form(data)

            http_resp = HTTP.basic_auth(user: user_full, pass: token)
                            .headers(accept: 'application/json')
                            .headers('Content-Type' => 'application/x-www-form-urlencoded')
                            .post(path, body: URI.encode_www_form(data))

            if http_resp.code == 201
              last       = client.job.get_builds(job_name).first
              reply_text = "Deploy started :rocket: for #{project} - <#{last['url']}console>"
            elsif http_resp.code == 401
              reply_text = ':no_mobile_phones: Unauthorized, check token or mention name'
            else
              log.info http_resp.inspect
              reply_text = 'Unknown error'
            end

            response.reply reply_text
          rescue Exception => e
            response.reply "Deploy failed, check params :shia: #{e}"
          end
        else
          response.reply "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      def build(response)
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
          user_token = redis.get("#{username}:token")
          if user_token.nil?
            'Token not found, you need set token via "lita jenkins auth set_token <token>" command'
          else
            'Token already set, you can play with Jenkins'
          end
        when 'set'
          user_token = response.matches.last.last.strip

          if redis.set("#{username}:token", user_token)
            unless redis.get("#{username}:notify")
              redis.set("#{username}:notify", 'false')
            end
            'Token saved, enjoy!'
          else
            'We have some troubles, try later'
          end
        when 'del'
          user_token = redis.get("#{username}:token")

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

      def set_notify_mode(response)
        username = response.user.mention_name
        mode     = response.matches.last.reject(&:blank?).first

        if mode.nil?
          current_mode = redis.get("#{username}:notify")
          response.reply "Current notify mode is `#{current_mode}`"
        # elsif ['none', 'direct', 'channel', 'smart'].include?(mode)
        elsif ['true', 'false'].include?(mode)
          redis.set("#{username}:notify", mode)
          response.reply ":yay: Notify mode `#{mode}` saved"
        else
          response.reply ":wat: Unknown notify mode `#{mode}`"
        end
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
            slackmoji = color_to_slackmoji(job['color'])
            answer << "#{n + 1}. <#{job['url']}|#{job['name']}> - #{job['color']} #{slackmoji}\n"
          end
          response.reply answer
        else
          response.reply "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      private

      def make_client(username)
        log.info "Trying user - #{username}"
        user_token = redis.get("#{username}:token")

        if user_token.nil?
          false
        else
          JenkinsApi::Client.new(
            server_ip: config.server,
            server_port: '443',
            username: "#{username}@#{config.org_domain}",
            password: user_token,
            ssl: true,
            log_level: 3
          )
        end
      end

      def color_to_slackmoji(color)
        case color
        when 'notbuilt'
          ':new:'
        when 'blue'
          ':woohoo:'
        when 'disabled'
          ':no_bicycles:'
        when 'red'
          ':wide_eye_pepe:'
        when 'yellow'
          ':pikachu:'
        when 'aborted'
          ':ultrarage:'
        end
      end
    end

    Lita.register_handler(Jenkins)
  end
end
