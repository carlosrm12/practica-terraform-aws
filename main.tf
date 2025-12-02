# main.tf

provider "aws" {
  region = "us-east-1"
}

# -------------------------------------------------------------------------
# 1. BUSQUEDA DE DATOS (Data Sources)
# Aquí buscamos lo que ya existe en AWS para usarlo.
# -------------------------------------------------------------------------

# REQUISITO: AMI Amazon Linux 2023 con Kernel 6.1
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
  
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Buscamos la VPC por defecto
data "aws_vpc" "default" {
  default = true
}

# REQUISITO: Subnets en zonas A, B y C exclusivamente.
data "aws_subnets" "mis_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    # Esto garantiza que el ALB y las instancias solo vivan aquí
    values = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

# -------------------------------------------------------------------------
# 2. SEGURIDAD (Firewalls)
# -------------------------------------------------------------------------

# SG del Load Balancer: Acepta tráfico de todo el mundo (Internet)
resource "aws_security_group" "alb_sg" {
  name        = "alb-security-group-tf"
  description = "Permitir HTTP publico"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG de las Instancias: Solo acepta tráfico del Load Balancer
resource "aws_security_group" "instancia_sg" {
  name        = "instancias-security-group-tf"
  description = "Trafico interno desde ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Enlace de seguridad
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------------------------------------------------------
# 3. COMPUTO (Launch Template)
# -------------------------------------------------------------------------

resource "aws_launch_template" "mi_template" {
  name_prefix   = "lt-t3-micro-"
  image_id      = data.aws_ami.al2023.id
  
  # REQUISITO: Instancia t3.micro
  instance_type = "t3.micro"
  
  # REQUISITO: Usar la llave existente vockey
  key_name      = "Laptop"

  vpc_security_group_ids = [aws_security_group.instancia_sg.id]

  # SCRIPT DE INICIO (USER DATA)
  # Instala Docker, crea el HTML y corre el contenedor automáticamente.
  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y docker
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ec2-user
              
              mkdir -p /home/ec2-user/web
              
              # Creamos el HTML dinámico
              cat <<EOT > /home/ec2-user/web/index.html
              <!DOCTYPE html><html lang="es"><head>
              <meta charset="UTF-8"><title>Terraform Project</title>
              <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"></head>
              <body class="bg-dark text-white"><div class="container text-center mt-5">
              <div class="card bg-secondary text-white shadow-lg">
                <div class="card-body">
                  <h1 class="display-4">¡Proyecto Automatizado!</h1>
                  <hr>
                  <p class="lead">Zona de Disponibilidad: <strong>t3.micro</strong></p>
                  <p>Desplegado via GitHub Actions</p>
                  <button class="btn btn-success">Estado: Healthy</button>
                </div>
              </div></div></body></html>
              EOT

              # Dockerfile
              echo "FROM httpd:2.4" > /home/ec2-user/web/Dockerfile
              echo "COPY ./index.html /usr/local/apache2/htdocs/" >> /home/ec2-user/web/Dockerfile
              
              # Ejecución
              cd /home/ec2-user/web
              docker build -t mi-web .
              docker run -d -p 80:80 --restart always --name web-container mi-web
              EOF
              )
}

# -------------------------------------------------------------------------
# 4. LOAD BALANCER & AUTO SCALING
# -------------------------------------------------------------------------

resource "aws_lb" "mi_alb" {
  name               = "alb-terraform-final"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.mis_subnets.ids # Zonas a, b, c
}

resource "aws_lb_target_group" "mi_tg" {
  name     = "tg-terraform-final"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  
  health_check {
    path = "/"
    matcher = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.mi_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mi_tg.arn
  }
}

resource "aws_autoscaling_group" "mi_asg" {
  name                = "asg-terraform-final"
  vpc_zone_identifier = data.aws_subnets.mis_subnets.ids
  target_group_arns   = [aws_lb_target_group.mi_tg.arn]
  
  desired_capacity    = 2
  max_size            = 10
  min_size            = 2
  
  launch_template {
    id      = aws_launch_template.mi_template.id
    version = "$Latest"
  }
  
  health_check_type         = "ELB"
  health_check_grace_period = 300
}

# REQUISITO: Política de escalado CPU > 10%
resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "politica-cpu-10-porciento"
  autoscaling_group_name = aws_autoscaling_group.mi_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 10.0
  }
}

# Output para que veas el link al final
output "load_balancer_dns" {
  value = aws_lb.mi_alb.dns_name
}