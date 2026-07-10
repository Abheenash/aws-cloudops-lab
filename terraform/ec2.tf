data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.prefix}-app-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    db_secret_arn = aws_db_instance.main.master_user_secret[0].secret_arn
    db_host       = aws_db_instance.main.address
    db_name       = var.db_name
    region        = var.region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name          = "${var.prefix}-app"
      "Patch Group" = "${var.prefix}-app" # consumed by SSM Patch Manager
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.prefix}-app-asg"
  desired_capacity          = var.asg_desired
  min_size                  = var.asg_desired
  max_size                  = var.asg_desired + 2
  vpc_zone_identifier       = aws_subnet.public[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-app"
    propagate_at_launch = true
  }
  tag {
    key                 = "Patch Group"
    value               = "${var.prefix}-app"
    propagate_at_launch = true
  }
}
