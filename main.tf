# main.tf

# ---------------------------------------------------------
# 1. CONFIGURACIÓN DEL ESTADO (S3)
# ---------------------------------------------------------
terraform {
  # Usamos la nube de HashiCorp en lugar de S3
  cloud {
    organization = "org-distribuida-carlos-practica" # Ej: org-estudiante-carlos

    workspaces {
      name = "practica-aws" # El nombre que pusiste al workspace
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------
# 2. VARIABLES
# ---------------------------------------------------------
variable "commit_hash" {
  description = "Hash del commit para forzar actualizacion del Launch Template"
  type        = string
  default     = "latest"
}

# ---------------------------------------------------------
# 3. BUSQUEDA DE DATOS
# ---------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "mis_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

# ---------------------------------------------------------
# 4. SEGURIDAD
# ---------------------------------------------------------
resource "aws_security_group" "alb_sg" {
  name        = "alb-security-group-pro"
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

resource "aws_security_group" "instancia_sg" {
  name        = "instancias-security-group-pro"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
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

# ---------------------------------------------------------
# 5. COMPUTO (Launch Template con Git Clone)
# ---------------------------------------------------------
resource "aws_launch_template" "mi_template" {
  name_prefix   = "lt-git-build-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"
  
  # ⚠️ CAMBIO 2: VERIFICA EL NOMBRE DE TU KEY PAIR
  key_name      = "Laptop"

  vpc_security_group_ids = [aws_security_group.instancia_sg.id]

  user_data = base64encode(<<-EOF
              #!/bin/bash
              
              # --- CONTROL DE VERSION (No borrar) ---
              # Commit Hash: ${var.commit_hash}
              # --------------------------------------

              dnf update -y
              dnf install -y docker git
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ec2-user
              
              mkdir -p /home/ec2-user/app
              cd /home/ec2-user/app

              # ⚠️ CAMBIO 3: PON LA URL HTTPS DE TU REPO
              git clone https://github.com/carlosrm12/practica-terraform-aws.git .
              
              # Construir Docker usando el Dockerfile que acabamos de bajar
              docker build -t mi-web .
              
              # Correr el contenedor
              docker run -d -p 80:80 --restart always --name web-container mi-web
              EOF
              )
}

# ---------------------------------------------------------
# 6. LOAD BALANCER & ASG
# ---------------------------------------------------------
resource "aws_lb" "mi_alb" {
  name               = "alb-final-pro"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.mis_subnets.ids
}

resource "aws_lb_target_group" "mi_tg" {
  name     = "tg-final-pro"
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
  name                = "asg-final-pro"
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

resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "politica-cpu-10"
  autoscaling_group_name = aws_autoscaling_group.mi_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 10.0
  }
}

output "dns_load_balancer" {
  value = aws_lb.mi_alb.dns_name
}