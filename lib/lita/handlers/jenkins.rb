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

      route /j(?:enkins)?(\W+)?d(?:eploy)?(\W+)?([\w\-\.]+)(\W+)?([\w\-\,]+)?(\W+)?to(\W+)?([\w\-]+)(\W+)?([\w]+)?/i, :deploy, command: true, help: {
        'jenkins d(eploy) <branch> <project1,project2> to <stage>' => 'Start dynamic deploy with params. Не выбранный бренч, зальет версию продакшна.'
      }

      on :loaded, :loop

      def loop(response)
        Thread.abort_on_exception = true
        every(10) do |timer|
          begin
            begin
              hash = JSON.parse(redis.get('notify'))
            rescue Exception => e
              redis.set('notify', {}.to_json)
              hash = JSON.parse(redis.get('notify'))
            end

            log.debug 'Make client for notify'

            begin
              client = make_client(config.notify_user)
            rescue
              sleep 60
              client = make_client(config.notify_user)
            end

            def process_job(hash, job_name, last_build, client)
              log.debug 'Inside process_job'
              hash[job_name] += 1
              log.debug "/job/#{job_name}/#{hash[job_name]}/api/json"
              begin
                log.debug 'Inside begin build'
                build = client.api_get_request("/job/#{job_name}/#{hash[job_name]}/api/json")
              rescue JenkinsApi::Exceptions::NotFound => e
                log.debug 'Resuce begin build redis set'
                redis.set('notify', hash.to_json)
                log.debug 'Again run process_job'
                process_job(hash, job_name, last_build, client) if hash[job_name] < last_build
                return
              rescue Exception => e
                log.debug 'Rescue other errors'
                log.debug e.message
                return
              end
              cause = build['actions'].select { |e| e['_class'] == 'hudson.model.CauseAction' }
              user_cause = cause.first['causes'].select { |e| e['_class'] == 'hudson.model.Cause$UserIdCause' }.first
              return if build['building']
              unless user_cause.nil?
                user         = user_cause['userId'].split('@').first
                runned       = build['displayName']
                build_number = hash[job_name]
                started      = build['timestamp']
                duration     = build['duration']
                result       = build['result']
                url          = build['url']

                unless notify_mode = redis.get("#{user}:notify")
                  log.debug 'Inside unless notify mode'
                  redis.set("#{user}:notify", 'false')
                  log.debug 'Set notify mode false'
                  notify_mode = 'false'
                end

                if notify_mode == 'true'
                  if result == 'SUCCESS'
                    color = 'good'
                  elsif result == 'FAILURE'
                    color = 'danger'
                  else
                    color = 'warning'
                  end

                  started    = started.to_i / 1000
                  duration   = duration.to_i / 1000
                  time       = Time.at(started).strftime("%d-%m-%Y %H:%M:%S")
                  text       = "Result for #{job_name} #{build_number} started on #{time} for #{runned} is #{result}\nDuration: #{duration} sec"
                  attachment = Lita::Adapters::Slack::Attachment.new(
                    text, {
                      title: 'Build status',
                      title_link: url,
                      text: text,
                      color: color
                    }
                  )
                  lita_user = Lita::User.find_by_mention_name(user)
                  log.info text
                  robot.chat_service.send_attachment(lita_user, attachment)
                end
              end
              redis.set('notify', hash.to_json)
              process_job(hash, job_name, last_build, client) if hash[job_name] < last_build
            end

            log.debug 'List_all_with_details'
            client.job.list_all_with_details.each do |jjob|
              log.debug 'Inside list_all_with_details'
              unless jjob['color'] == 'disabled' || jjob['color'] == 'notbuilt'
                log.debug 'Inside unless'

                begin
                  last_build = client.job.get_builds(jjob['name']).first['number']
                rescue Exception => e
                  puts e.message
                  next
                end

                if hash[jjob['name']]
                  log.debug 'if hash'
                  if hash[jjob['name']] < last_build
                    log.debug 'If hash < last_build'
                    process_job(hash, jjob['name'], last_build, client)
                  end
                else
                  log.debug 'else if no hash'
                  hash[jjob['name']] = last_build
                  redis.set('notify', hash.to_json)
                end
              end
            end
          rescue Exception => e
            log.debug "Error in notify thread: #{e}"
            self.loop('again')
          end
        end
      end

      def deploy(response)
        params     = response.matches.last.reject(&:blank?) #["OTT-123", "avia", "sandbox-15"]
        project    = ''
        branch     = ''
        stage      = ''
        flag       = nil
        job_name   = 'dynamic_deploy'
        job_params = {}
        opts       = { 'build_start_timeout': 30 }
        username   = response.user.mention_name

        if params.size == 3
          branch  = params[0]
          project = params[1]
          stage   = params[2]
        elsif params.size == 2
          project = params[0]
          stage   = params[1]
        elsif params.size == 4
          branch  = params[0]
          project = params[1]
          stage   = params[2]
          flag    = params[3]
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
          if flag.nil?
            job_params['PROJECTS'][proj.upcase] = {
              'ENABLE' => true,
              'BRANCH' => branch
            }
          else
            if flag == 'migrate'
              job_params['PROJECTS'][proj.upcase] = {
                'ENABLE' => true,
                'BRANCH' => branch,
                'ExtraOpts' => {
                  'DBMIGRATION' => true
                }
              }
            elsif flag == 'rollback'
              job_params['PROJECTS'][proj.upcase] = {
                'ENABLE' => true,
                'BRANCH' => branch,
                'ExtraOpts' => {
                  'DBROLLBACK' => true
                }
              }
            else
              response.reply 'Something wrong with flag (it is a last param) :fire:'
              return
            end
          end
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
            timeout: 60,
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
