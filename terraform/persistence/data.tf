# Se piden las AZs disponibles dinámicamente en vez de hardcodear
# "us-east-1a"/"us-east-1b": algunas cuentas tienen AZs distintas
# habilitadas/deshabilitadas, así que esto es más portable.
data "aws_availability_zones" "available" {
  state = "available"
}
