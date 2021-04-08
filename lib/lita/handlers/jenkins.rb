require 'jenkins_api_client'
require 'json'
require 'http'
require 'uri'
require 'securerandom'

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

      route /j(?:enkins)?(\W+)?d(?:eploy)?(\W+)?(.+)/i, :deploy, command: true, help: {
        'jenkins d(eploy) <branch> <project1,project2> to <stage>' => 'Start dynamic deploy with params. Не выбранный бренч, зальет версию продакшна.'
      }

      on :loaded, :loop

      def loop(response)
        Thread.abort_on_exception = true
        every(10) do |timer|
          begin

            log.info 'Make client for notify'
            client = make_client(config.notify_user)

            log.debug 'Check if hist empty'
            flag   = redis.get('notify:flag')

            # Scheduler
            if flag == 'true'
              begin
                jobs = client.job.list_all_with_details
              rescue Exception => e
                log.debug "Can't get jobs due error: #{e.message} #{e.backtrace}"
              end

              unless jobs.nil?
                jobs.each do |job|
                  unless ['disabled', 'notbuilt'].include?(job['color'])
                    begin
                      builds = client.job.get_builds(job['name'])
                    rescue Exception => e
                      log.debug "Can't get builds due error: #{e.message} #{e.backtrace}"
                    end

                    unless builds.nil?
                      builds.each do |build|

                        queue = redis.lrange "notify:queue:#{job['name']}", 0, -1
                        hist  = redis.lrange "notify:hist:#{job['name']}", 0, -1
                        numb  = build['number'].to_s

                        if queue.include?(numb)
                          log.debug "#{job['name']}:#{numb} already in queue"
                        elsif hist.include?(numb)
                          log.debug "#{job['name']}:#{numb} already in hist"
                        else
                          log.debug "#{job['name']}:#{numb} push to queue"
                          redis.rpush "notify:queue:#{job['name']}", numb
                        end
                      end
                    end
                  end
                end
              end
            else
              begin
                jobs = client.job.list_all_with_details
              rescue Exception => e
                log.debug "Can't get jobs due error: #{e.message} #{e.backtrace}"
              end

              unless jobs.nil?
                jobs.each do |job|
                  unless ['disabled', 'notbuilt'].include?(job['color'])
                    client.job.get_builds(job['name']).each do |build|
                      log.debug "#{job['name']}:#{build['number']} push to hist"
                      redis.rpush "notify:hist:#{job['name']}", build['number']
                    end
                  end
                end
              end
              redis.set('notify:flag', 'true')
            end

            # Worker
            jobs_in_queue_wait = redis.keys('notify:queue_wait:*')
            if jobs_in_queue_wait.empty?
              log.debug 'Notify: No jobs in queue_wait'
            else
              jobs_in_queue_wait.each do |job|
                job_name = job.split(':').last
                until redis.llen job == 0
                  redis.rpoplpush job "notify:queue:#{job_name}"
                end
              end
            end

            jobs_in_queue = redis.keys('notify:queue:*')
            if jobs_in_queue.empty?
              log.debug 'Notify: No jobs in queue'
            else
              jobs_in_queue.each do |job|
                def process_job(build_number, job_name, client)
                  job_id = "#{job_name}:#{build_number}"

                  url = "/job/#{job_name}/#{build_number}/api/json"
                  log.debug "#{job_id} Getting build info for url #{url}"

                  begin
                    build = client.api_get_request(url)
                  rescue JenkinsApi::Exceptions::NotFound
                    log.debug "#{job_id} Build info not found, will skip"
                    redis.rpush "notify:hist:#{job_name}", build_number
                  end

                  cause      = build['actions'].select { |e| e['_class'] == 'hudson.model.CauseAction' }
                  user_cause = cause.first['causes'].select { |e| e['_class'] == 'hudson.model.Cause$UserIdCause' }.first

                  unless user_cause.nil?
                    if build['building']
                      log.debug "#{job_id} Job is building will skip"
                      redis.lpush "notify:queue_wait:#{job_name}", build_number
                      return
                    end

                    log.debug "#{job_id} Job cause by user #{user_cause['userId']}"

                    user     = user_cause['userId'].split('@').first
                    runned   = build['displayName']
                    started  = build['timestamp']
                    duration = build['duration']
                    result   = build['result']
                    url      = build['url']

                    debug_text = {
                      user: user,
                      runned: runned,
                      build_number: build_number,
                      started: started,
                      duration: duration,
                      result: result,
                      url: url
                    }
                    log.debug "#{job_id} #{debug_text}"

                    unless notify_mode = redis.get("#{user}:notify")
                      log.debug "#{job_id} No notify mode choosen for user"
                      redis.set("#{user}:notify", 'false')

                      log.debug "#{job_id} Set notify mode false"
                      notify_mode = 'false'
                    end

                    # if ['true', 'direct', 'channel', 'smart'].include?(notify_mode)
                    if notify_mode == 'true'
                      log.debug "#{job_id} Notify mode true will notify"

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
                      debug_text  = {for_user: user, message: text}
                      log.info "#{job_id} #{debug_text}"
                      robot.chat_service.send_attachment(lita_user, attachment)
                    end
                  else
                    log.debug "#{job_id} Triggered not by user, will skip"
                  end

                  log.debug "#{job_id} Finished"
                  redis.rpush "notify:hist:#{job_name}", build_number
                end

                job_name = job.split(':').last

                build_number = redis.lpop job
                until build_number.nil?
                  process_job(build_number, job_name, client)
                  build_number = redis.lpop job
                end
              end
            end
          rescue Exception => e
            log.error "Error in notify thread: #{e.message} #{e.backtrace}"
            sleep 60
            self.loop('again')
          end
        end
      end

      def deploy(response)
        string = response.matches.last.reject(&:blank?).first #["OTT-123", "avia", "sandbox-15"]
        req_id = SecureRandom.uuid
        log.info "[DEPLOY_REQUEST:#{req_id}] #{string.inspect}"

        project     = 'nil'
        branch      = 'nil'
        stage       = 'nil'
        checkmaster = false
        params      = {}

        core = string.split(' to ')
        core.map! { |c| c.strip }

        if core.length == 2
          base = core.first.split

          if base.empty?
            response.reply 'No base params like project, branch and stage'
            return
          elsif base.length == 1
            project = base.first
          elsif base.length == 2
            branch  = base.first
            project = base.last
          else
            response.reply 'To many base params (before to)'
            return
          end

          params_array = core.last.split
          stage        = params_array.shift

          params_array.each do |param|
            if param == 'migrate'
              params['DBMIGRATION'] = true
            elsif param == 'rollback'
              params['DBROLLBACK'] = true
            elsif param == 'checkmaster'
              checkmaster = true
            elsif param == 'restart_only'
              params['RESTART_ONLY'] = true
            elsif param.split(':').length == 2
              key, value = param.split(':')
              # value = value_map(value)
              params[key.upcase] = value
            else
              response.reply "Unknown param #{param}"
              return
            end
          end
        else
          response.reply 'To many "to"'
          return
        end

        if params.keys.include?('DBMIGRATION') && params.keys.include?('DBROLLBACK')
          response.reply 'A U FCK KIDDING ME? Choose what you rly want migrate or rollback! :bad:'
          return
        end

        job_name   = 'dynamic_deploy'
        job_params = {}
        username   = response.user.mention_name

        log.info "[DEPLOY_REQUEST:#{req_id}] branch:#{branch} project:#{project} stage:#{stage} params:#{params.inspect}"

        projects = project.split(',')
        branches = branch.split(',')
        stages   = stage.split(',')

        log.info "[DEPLOY_REQUEST:#{req_id}] branches:#{branches} projects:#{projects} stages:#{stages}"

        if branches.length > projects.length
          response.reply 'A U FCK KIDDING ME? Choose which branch you rly want to deploy! :bad:'
          return
        elsif branches.length < projects.length && branches.length > 1
          response.reply "Not enough #{branches.length} branches for #{projects.length} projects :feelsbadman:"
          return
        # elsif [projects.length, branches.length, stages.length].uniq.length == 1
        elsif branches.length == projects.length || (branches.length < projects.length && branches.length == 1)
          stages.each do |s|

            if ['staging', 'production-b', 'production-a', 'production', 'selectel', 'extranet'].include?(s)
              checkmaster = true
            end

            job_params = {
              'STAGE'       => s,
              'CHECKMASTER' => checkmaster,
              'PROJECTS'    => {}
            }

            projects.each_with_index do |proj, i|
              bran = branches.first
              bran = branches[i] if branches.length > 1

              if params.empty?
                job_params['PROJECTS'][proj.upcase] = {
                  'ENABLE' => true,
                  'BRANCH' => bran
                }
              else
                job_params['PROJECTS'][proj.upcase] = {
                  'ENABLE'    => true,
                  'BRANCH'    => bran,
                  'ExtraOpts' => params
                }
              end
            end

            client = make_client(username)

            if client
              begin

                user_full  = "#{username}@#{config.org_domain}"
                token      = redis.get("#{username}:token")
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

                start_time = time_now_ms
                http_resp = HTTP.basic_auth(user: user_full, pass: token)
                                .headers(accept: 'application/json')
                                .headers('Content-Type' => 'application/x-www-form-urlencoded')
                                .post(path, body: URI.encode_www_form(data))

                if http_resp.code == 201
                  job_url    = try_find_job_url(client, start_time, job_name, username, s)
                  unless job_url
                    job_url  = client.job.get_builds(job_name).first['url']
                  end
                  reply_text = "Deploy started :rocket: for #{project} - <#{job_url}console>"
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
        else
          response.reply 'U broke me :alert:'
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
        # elsif ['false', 'direct', 'channel', 'smart'].include?(mode)
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

      def time_now_ms
        (Time.now.to_f * 1000.0).to_i
      end

      def try_find_job_url(client, start_time, job_name, username, stage)
        end_time = start_time + 10000
        job_url = nil
        while time_now_ms < end_time do
          jobs = client.job.get_builds(job_name, { tree: "builds[number,url,displayName,timestamp,actions[causes[userId]]]{0,20}" })
          jobs.each do |job|
            next if job['displayName'] != stage || job['timestamp'].to_i < start_time
            causes = job['actions'].map { |act| act['causes'] }.compact.flatten
            if causes.dig(0, 'userId') == "#{username}@#{config.org_domain}"
              job_url = job['url']
              break
            end
          end
          break if job_url
          sleep(3) # wait 3 seconds
        end
        job_url
      end

      def make_client(username)
        log.info "Trying user - #{username}"
        user_token = redis.get("#{username}:token")

        if user_token.nil?
          false
        else
          JenkinsApi::Client.new(
            server_ip:   config.server,
            server_port: '443',
            username:    "#{username}@#{config.org_domain}",
            password:    user_token,
            ssl:         true,
            timeout:     60,
            log_level:   3
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
