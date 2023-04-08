data "aws_subnet" "this" {
  for_each = var.targets
  id       = each.value["subnet_id"]
}

data "aws_vpc" "this" {
  for_each = var.targets
  id       = data.aws_subnet.this[each.key].vpc_id
}

resource "aws_security_group" "this" {
  for_each    = var.targets
  name        = format("%s-patcher-sg", each.key)
  description = "Security Group used in an Orphan Instance by SSM Patcher"
  vpc_id      = data.aws_vpc.this[each.key].id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.this[each.key].cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}