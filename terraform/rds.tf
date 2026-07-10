resource "aws_db_subnet_group" "main" {
  name       = "${var.prefix}-db-subnets"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.prefix}-db-subnets" }
}

resource "aws_db_instance" "main" {
  identifier     = "${var.prefix}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = "copsadmin"
  # No password in code: RDS creates and rotates a Secrets Manager secret.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false
  publicly_accessible    = false

  # Backups: daily automated snapshots — the source for the restore-test drill.
  backup_retention_period      = 7
  backup_window                = "07:00-07:30"
  maintenance_window           = "Sun:08:00-Sun:08:30"
  delete_automated_backups     = true
  skip_final_snapshot          = true
  deletion_protection          = false
  apply_immediately            = true
  performance_insights_enabled = true

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = { Name = "${var.prefix}-db" }
}
