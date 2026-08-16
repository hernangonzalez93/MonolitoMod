# RDS exige un "DB Subnet Group": la lista de subredes (de al menos 2 AZs
# distintas) donde puede llegar a colocar la instancia. Usa las 2 subredes
# privadas de la Fase 9.
resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version

  instance_class    = var.db_instance_class
  allocated_storage = 20 # GB — el mínimo permitido, de sobra para este estudio
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  # manage_master_user_password: RDS genera la contraseña y la guarda en
  # Secrets Manager por su cuenta — el password en texto plano NUNCA pasa
  # por el código de Terraform ni queda escrito en el .tfstate, a diferencia
  # de generar una contraseña con el provider "random" y asignarla a mano.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # publicly_accessible = false es la garantía central de esta fase: aunque
  # alguien intentara conectarse desde internet con las credenciales
  # correctas, no hay ninguna ruta de red para siquiera intentarlo (ver
  # Fase 9: esta VPC no tiene Internet Gateway).
  publicly_accessible = false

  multi_az = false # instancia unica: un estudio no necesita alta disponibilidad, y multi-AZ duplica el costo

  backup_retention_period = 1     # minimo util; el almacenamiento de backups es gratis hasta el tamano de la DB
  skip_final_snapshot     = true  # evita que "terraform destroy" quede esperando/creando un snapshot final (y su costo de storage)
  deletion_protection     = false # simplifica destruir/recrear durante el estudio, a costa de no tener el seguro de "no te dejo borrar esto sin querer"
}
