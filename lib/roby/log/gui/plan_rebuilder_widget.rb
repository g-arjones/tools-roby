module Roby
    module LogReplay
        # This widget displays information about the event history in a list,
        # allowing to switch between the "important events" in this history
        class PlanRebuilderWidget < Qt::Widget
            # The list used to display all the cycles in the history
            attr_reader :list
            # The history, as a mapping from the cycle index to a (time,
            # snapshot, list_item) triple
            attr_reader :history
            # The PlanRebuilder object we use to process the log data
            attr_reader :plan_rebuilder
            # The current plan managed by the widget
            attr_reader :current_plan

            # Signal emitted when an informational message is meant to be
            # displayed
            signals 'info(QString)'
            # Signal emitted when a warning message is meant to be displayed
            signals 'warn(QString)'
            # Signal emitted when the currently displayed cycle changed, i.e.
            # when displays are supposed to be updated
            signals 'update(QDateTime)'

            def initialize(parent, plan_rebuilder = nil)
                super(parent)
                @list    = Qt::ListWidget.new(self)
                @layout  = Qt::VBoxLayout.new(self)

                @layout.add_widget(@btn_create_display)
                @history = Hash.new
                @plan_rebuilder = plan_rebuilder
                @current_plan = Roby::Plan.new
                @current_plan.extend ReplayPlan
                @layout.add_widget(list)

                Qt::Object.connect(list, SIGNAL('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'),
                           self, SLOT('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'))
            end

            def add_missing_cycles(count)
                item = Qt::ListWidgetItem.new(list)
                item.setBackground(Qt::Brush.new(Qt::Color::fromHsv(33, 111, 255)))
                item.flags = Qt::NoItemFlags
                item.text = "[#{count} cycles missing]"
            end

            def append_to_history(snapshot)
                cycle = snapshot.stats[:cycle_index]
                time = Time.at(*snapshot.stats[:start]) + snapshot.stats[:real_start]

                item = Qt::ListWidgetItem.new(list)
                item.text = "@#{cycle} - #{Roby.format_time(time)}"
                item.setData(Qt::UserRole, Qt::Variant.new(cycle))
                history[cycle] = [time, snapshot, item]
            end

            slots 'currentItemChanged(QListWidgetItem*,QListWidgetItem*)'
            def currentItemChanged(new_item, previous_item)
                data = new_item.data(Qt::UserRole).toInt
                apply(history[data][1])
            end

            def apply(snapshot)
                @current_plan.owners.clear
                Distributed.disable_ownership do
                    @current_plan.clear
                    @current_time = Time.at(*snapshot.stats[:start]) + snapshot.stats[:end]
                    snapshot.apply(@current_plan)
                end
                emit update(Qt::DateTime.new(@current_time))
            end

            def seek(time)
                # Convert from QDateTime to allow seek() to be a slot
                if time.kind_of?(Qt::DateTime)
                    time = Time.at(Float(time.toMSecsSinceEpoch) / 1000)
                end

                result = nil
                history.each_value do |cycle_time, snapshot, item|
                    if cycle_time < time
                        if !result || result[0] < cycle_time
                            result = [cycle_time, snapshot]
                        end
                    end
                end
                if result
                    apply(result[1])
                end
            end
            slots 'seek(QDateTime)'


            attr_reader :last_cycle
            attr_reader :last_cycle_snapshotted

            def push_data(data)
                needs_snapshot = plan_rebuilder.push_data(data)
                cycle = plan_rebuilder.stats[:cycle_index]
                if last_cycle && (cycle != last_cycle + 1)
                    add_missing_cycles(cycle - last_cycle - 1)
                end
                if needs_snapshot
                    append_to_history(plan_rebuilder.history.last)
                end
                @last_cycle = cycle
            end

            # Opens +filename+ and reads the data from there
            def open(filename)
                stream = Roby::LogReplay::EventFileStream.open(filename)
                self.window_title = "roby-display: #{filename}"
                emit sourceChanged
                analyze(stream)
                if !history.empty?
                    apply(history[history.keys.sort.first][1])
                end
            end

            signals 'sourceChanged()'

            def analyze(stream, display_progress = true)
                start = Time.now
                start_time, end_time = stream.range

                dialog = Qt::ProgressDialog.new("Analyzing log file", "Quit", 0, (end_time - start_time))
                dialog.setWindowModality(Qt::WindowModal)
                dialog.show

                @last_cycle = nil
                while !stream.eof?
                    data = stream.read
                    push_data(data)
                    dialog.setValue(plan_rebuilder.time - start_time)
                    if dialog.wasCanceled
                        Kernel.raise Interrupt
                    end
                end
                dialog.dispose
                puts "analyzed log file in %.2fs" % [Time.now - start]
            end

            # Called when the connection to the log server failed, either
            # because it has been closed or because creating the connection
            # failed
            def connection_failed(e, client, options)
                @connection_error = e
                emit warn("connection failed: #{e.message}")
                if @reconnection_timer
                    return
                end

                @reconnection_timer = Qt::Timer.new(self)
                @connect_client  = client.dup
                @connect_options = options.dup
                @reconnection_timer.connect(SIGNAL('timeout()')) do
                    puts "trying to reconnect to #{@connect_client} #{@connect_options}"
                    if connect(@connect_client, @connect_options)
                        emit info("Connected")
                        @reconnection_timer.stop
                        @reconnection_timer.dispose
                        @reconnection_timer = nil
                    end
                end
                @reconnection_timer.start(1000)
            end

            DEFAULT_REMOTE_POLL_PERIOD = 0.05

            # Displays the data incoming from +client+
            #
            # +client+ is assumed to be a Roby::Log::Client instance
            #
            # +update_period+ is, in seconds, the period at which the
            # display will check whether there is new data on the port.
            def connect(client, options = Hash.new)
                options = Kernel.validate_options options,
                    :port => Roby::Log::Server::DEFAULT_PORT,
                    :update_period => DEFAULT_REMOTE_POLL_PERIOD

                if client.respond_to?(:to_str)
                    self.window_title = "roby-display: #{client}"
                    emit sourceChanged

                    begin
                        hostname = client
                        client = Roby::Log::Client.new(client, options[:port])
                    rescue Exception => e
                        connection_failed(e, client, options)
                        return false
                    end
                end


                @client = client
                client.add_listener do |data|
                    push_data(data)

                    cycle = plan_rebuilder.cycle_index
                    time = plan_rebuilder.time
                    emit info("@#{cycle} - #{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}")
                end
                @connection_pull = timer = Qt::Timer.new(self)
                timer.connect(SIGNAL('timeout()')) do
                    begin
                        client.read_and_process_pending
                    rescue Exception => e
                        disconnect
                        emit warn("Disconnected: #{e.message}")
                        puts e.message
                        puts "  " + e.backtrace.join("\n  ")
                        if hostname
                            connect(hostname, options)
                        end
                    end
                end
                timer.start(Integer(options[:update_period] * 1000))
                return true
            end

            def disconnect
                @client.disconnect
                @connection_pull.stop
                @connection_pull.dispose
                @connection_pull = nil
            end

            def time
                plan_rebuilder.time
            end

            def start_time
                plan_rebuilder.start_time
            end
        end

	module TaskDisplayConfiguration
            # A set of prefixes that should be removed from the task names
	    attribute(:removed_prefixes) { Set.new }

            # Any task whose label matches one regular expression in this set is
            # not displayed
            attribute(:hidden_labels) { Array.new }

	    # Compute the prefixes to remove from in filter_prefixes:
	    # enable only the ones that are flagged, and sort them by
	    # prefix length
	    def update_prefixes_removal
		@prefixes_removal = removed_prefixes.to_a.
                    sort_by { |p| p.length }.
		    reverse
	    end

            def filtered_out_label?(label)
                (!hidden_labels.empty? && hidden_labels.any? { |match| label.include?(match) })
            end

	    def filter_prefixes(string)
		# @prefixes_removal is computed in RelationsCanvas#update
		for prefix in @prefixes_removal
		    string = string.gsub(prefix, '')
		end
                if string =~ /^::/
                    string = string[2..-1]
                end
		string
	    end

	    # If true, show the ownership in the task descriptions
	    attribute(:show_ownership) { true }
	    # If true, show the arguments in the task descriptions
	    attribute(:show_arguments) { false }
	end
    end
end

