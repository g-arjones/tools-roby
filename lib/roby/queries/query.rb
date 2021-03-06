module Roby
    module Queries
    # A query is a TaskMatcher that applies on a plan. It should, in general, be
    # preferred to TaskMatcher as it uses task indexes to be more efficient.
    #
    # Queries cache their result. I.e. once #each has been called to get the
    # query results, the query will always return the same results until #reset
    # has been called.
    class Query < TaskMatcher
        # The plan this query acts on
	attr_reader :plan

        # Create a query object on the given plan
	def initialize(plan = nil)
            @scope = :global
	    @plan = plan
	    super()
	    @plan_predicates = Set.new
	    @neg_plan_predicates = Set.new
	end

        def query
            self
        end

        # Search scope for queries on transactions. If equal to :local, the
        # query will apply only on the scope of the searched transaction,
        # otherwise it applies on a virtual plan that is the result of the
        # transaction stack being applied.
        #
        # The default is :global.
        #
        # See #local_scope and #global_scope
        attr_reader :scope

        # Changes the scope of this query. See #scope.
        def local_scope
            @scope = :local
            self
        end
        # Changes the scope of this query. See #scope.
        def global_scope
            @scope = :global
            self
        end

        # Changes the plan this query works on. This calls #reset (obviously)
        def plan=(new_plan)
            reset
            @plan = new_plan
        end

        # The set of tasks which match in plan. This is a cached value, so use
        # #reset to actually recompute this set.
	def result_set
	    @result_set ||= plan.query_result_set(self)
	end

        # Overload of TaskMatcher#filter
	def filter(initial_set, task_index)
            result = super

            if plan_predicates.include?(:mission_task?)
                result = result.intersection(plan.mission_tasks)
            elsif neg_plan_predicates.include?(:mission_task?)
                result.subtract(plan.mission_tasks)
            end

            if plan_predicates.include?(:permanent_task?)
                result = result.intersection(plan.permanent_tasks)
            elsif neg_plan_predicates.include?(:permanent_task?)
                result.subtract(plan.permanent_tasks)
            end

            result
        end

        # Reinitializes the cached query result.
        #
        # Queries cache their result, i.e. #each will always return the same
        # task set. #reset makes sure that the next call to #each will return
        # the same value.
	def reset
	    @result_set = nil
	    self
	end

        # The set of predicates of Plan which must return true for #=== to
        # return true
	attr_reader :plan_predicates
        # The set of predicates of Plan which must return false for #=== to
        # return true.
	attr_reader :neg_plan_predicates

	class << self
            # For each name in +names+, define the #name and #not_name methods
            # on Query objects. When one of these methods is called on a Query
            # object, plan.name?(task) must return true (resp. false) for the
            # task to match.
	    def match_plan_predicates(names)
		names.each do |name, predicate_name|
                    predicate_name ||= name
		    class_eval <<-EOD, __FILE__, __LINE__+1
		    def #{name}
			if neg_plan_predicates.include?(:#{predicate_name})
			    raise ArgumentError, "trying to match (#{name} & !#{name})"
		        end
			plan_predicates << :#{predicate_name}
			self
		    end
		    def not_#{name}
			if plan_predicates.include?(:#{predicate_name})
			    raise ArgumentError, "trying to match (#{name} & !#{name})"
		        end
			neg_plan_predicates << :#{predicate_name}
			self
		    end
		    EOD
		end
	    end
	end

        ##
        # :method: mission
        #
        # Filters missions
        #
        # Matches tasks in plan that are missions

        ##
        # :method: not_mission
        #
        # Filters out missions
        #
        # Matches tasks in plan that are not missions

        ##
        # :method: permanent
        #
        # Filters permanent tasks
        #
        # Matches tasks in plan that are declared as permanent tasks.

        ##
        # :method: not_permanent
        #
        # Filters out permanent tasks
        #
        # Matches tasks in plan that are not declared as permanent tasks

	match_plan_predicates mission: :mission_task?
        match_plan_predicates permanent: :permanent_task?
	
        # Filters tasks which have no parents in the query itself.
        #
        # Will filter out tasks which have parents in +relation+ that are
        # included in the query result.
	def roots(relation)
	    @result_set = plan.query_roots(result_set, relation)
	    self
	end

        # True if +task+ matches the query. Call #result_set to have the set of
        # tasks which match in the given plan.
	def ===(task)
	    for pred in plan_predicates
		return unless plan.send(pred, task)
	    end
	    for neg_pred in neg_plan_predicates
		return if plan.send(neg_pred, task)
	    end

	    return unless super

	    true
	end

        # Iterates on all the tasks in the given plan which match the query
        #
        # This set is cached, i.e. #each will yield the same task set until
        # #reset is called.
	def each(&block)
            return enum_for(__method__) if !block_given?
	    plan.query_each(result_set, &block)
	end
	include Enumerable
    end
    end
end

