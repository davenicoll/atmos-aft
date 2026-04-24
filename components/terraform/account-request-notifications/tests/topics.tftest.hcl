# Verifies the for_each shape of the sns_topic module: empty topics →
# no module instances, non-empty → one per map key.

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aft-request-notifications"
}

run "empty_topics_map_creates_no_modules" {
  command = plan

  variables {
    topics = {}
  }

  assert {
    condition     = length(module.sns_topic) == 0
    error_message = "With topics={}, no sns_topic module instances must be created."
  }
}

run "one_module_per_topic_key" {
  command = plan

  variables {
    topics = {
      success = {
        subscribers = {}
      }
      failure = {
        subscribers = {}
      }
    }
  }

  assert {
    condition     = length(module.sns_topic) == 2
    error_message = "One sns_topic module instance must be created per topics-map key."
  }

  assert {
    condition = alltrue([
      contains(keys(module.sns_topic), "success"),
      contains(keys(module.sns_topic), "failure"),
    ])
    error_message = "sns_topic for_each keys must match topics map keys (success, failure)."
  }
}
