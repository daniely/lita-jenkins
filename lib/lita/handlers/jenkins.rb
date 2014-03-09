module Lita
  module Handlers
    class Jenkins < Handler
      route /j(?:enkins)? list( (.+))?/i, :jenkins_list, command: true, help: {
        'jekins list <filter>' => 'lists Jenkins jobs'
      }

      def jenkins_list(response)
        filter = response.matches.first.first.downcase
      end
    end

    Lita.register_handler(Jenkins)
  end
end
