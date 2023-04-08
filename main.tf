resource "aws_ssm_maintenance_window" "this" {
  for_each = var.targets
  name     = format("%s-asg-maintenance-window", each.key)
  schedule = each.value["schedule"]
  duration = lookup(each.value, "duration", 3)
  cutoff   = lookup(each.value, "cutoff", 1)
  tags     = var.tags
}

resource "aws_ssm_maintenance_window_task" "this" {
  for_each         = var.targets
  priority         = 1
  task_arn         = aws_ssm_document.this.name
  task_type        = "AUTOMATION"
  window_id        = aws_ssm_maintenance_window.this[each.key].id
  service_role_arn = aws_iam_role.ssm.arn

  task_invocation_parameters {
    automation_parameters {
      document_version = "$LATEST"

      parameter {
        name   = "AutomationAssumeRole"
        values = [aws_iam_role.ssm.arn]
      }

      parameter {
        name   = "InstanceProfile"
        values = [aws_iam_instance_profile.ec2.name]
      }

      parameter {
        name   = "AmiParameter"
        values = [aws_ssm_parameter.ami[each.key].name]
      }

      parameter {
        name   = "LtParameter"
        values = [aws_ssm_parameter.lt[each.key].name]
      }

      parameter {
        name   = "LaunchTemplatePrefix"
        values = [each.key]
      }

      parameter {
        name   = "PatchBaselineName"
        values = [lookup(each.value, "patch_baseline", "AWS-RunPatchBaseline")]
      }

      parameter {
        name   = "SourceAMI"
        values = ["{{ ssm:${aws_ssm_parameter.ami[each.key].name} }}"]
      }

      parameter {
        name   = "NewAMI"
        values = [format("%s-patchedAMI-{{global:DATE_TIME}}", each.key)]
      }

      parameter {
        name   = "SubnetId"
        values = [each.value["subnet_id"]]
      }

      parameter {
        name   = "SecurityGroupIds"
        values = [aws_security_group.this[each.key].id]
      }

      parameter {
        name   = "TargetASG"
        values = [each.value["asg_name"]]
      }

      parameter {
        name   = "RebootOption"
        values = [lookup(each.value, "reboot_option", "RebootIfNeeded")]
      }

      parameter {
        name   = "Operation"
        values = [lookup(each.value, "operation", "Install")]
      }

      parameter {
        name   = "RetentionDays"
        values = [each.value["retention_days"]]
      }
    }
  }
}