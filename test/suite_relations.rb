$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'test_relations'
require 'relations/test_hierarchy'
require 'relations/test_executed_by'
require 'relations/test_planned_by'
require 'relations/test_conflicts'

require 'relations/test_ensured'
