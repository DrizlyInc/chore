require 'chore/signal'
require 'socket'
require 'chore/strategies/worker/helpers/ipc'
require 'chore/strategies/worker/helpers/preforked_worker'
require 'chore/strategies/worker/helpers/worker_manager'
require 'chore/strategies/worker/helpers/work_distributor'

module Chore
  module Strategy
    class PreForkedWorkerStrategy #:nodoc:
      include Ipc

      NUM_TO_SIGNAL = {  '1' => :CHLD,
                         '2' => :INT,
                         '3' => :QUIT,
                         '4' => :TERM
                      }.freeze

      def initialize(manager, opts = {})
        @options = opts
        @manager = manager
        @self_read, @self_write = IO.pipe
        trap_signals(NUM_TO_SIGNAL, @self_write)
        @worker_manager = WorkerManager.new(create_master_socket)
        @running = true
      end

      def start
        Chore.logger.info "PWS: Starting up worker strategy: #{self.class.name}"
        Chore.run_hooks_for(:before_first_fork)
        @worker_manager.create_and_attach_workers
        worker_assignment_thread
      end

      def stop!
        Chore.logger.info "PWS: Stopping worker strategy: #{self.class.name}"
        @running = false
      end

      private

      def worker_assignment_thread
        Thread.new do
          begin
            worker_assignment_loop
          rescue Chore::TerribleMistake => e
            Chore.logger.error 'PWS: Terrible mistake, shutting down Chore'
            Chore.logger.error e.message
            Chore.logger.error e.backtrace
            @manager.shutdown!
          end
        end
      end

      def worker_assignment_loop
        while running?
          w_sockets = @worker_manager.worker_sockets

          # select_sockets returns a list of readable sockets
          # This would include worker connections and the read end
          # of the self-pipe.
          readables, _, _ = select_sockets(w_sockets, @self_read)

          # If select timed out, retry
          if readables.nil?
            Chore.logger.debug "PWS: All sockets busy.. retry"
            next
          end

          # Handle the signal from the self-pipe
          if readables.include?(@self_read)
            handle_signal
            next
          end

          # Fetch and assign work for the readable worker connections
          @worker_manager.ready_workers(readables) do | workers |
            WorkDistributor.fetch_and_assign_jobs(workers, @manager)
          end
        end
      end

      # Wrapper need around running to help writing specs for worker_assignment_loop
      def running?
        @running
      end

      def handle_signal
        signal = NUM_TO_SIGNAL[@self_read.read_nonblock(1)]
        Chore.logger.debug "PWS: recv #{signal}"

        case signal
        when :CHLD
          @worker_manager.respawn_terminated_workers!
        when :INT, :QUIT, :TERM
          Signal.reset
          @worker_manager.stop_workers(signal)
          @manager.shutdown!
        end
      end

      # Wrapper around fork for specs.
      def fork(&block)
        Kernel.fork(&block)
      end

      # In the event of a trapped signal, write to the self-pipe
      def trap_signals(signal_hash, write_end)
        Signal.reset

        signal_hash.each do |sig_num, signal|
          Signal.trap(signal) do
            write_end.write(sig_num)
          end
        end
      end
    end
  end
end