resource "aws_ssm_parameter" "ami" {
  for_each = var.targets
  name     = format("/patch-asg/%s/SourceAMI", each.key)
  type     = "String"
  value    = each.value["initial_ami"]
  tags     = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "lt" {
  for_each = var.targets
  name     = format("/patch-asg/%s/LaunchTemplateID", each.key)
  type     = "String"
  value    = "initial_any_string"
  tags     = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}