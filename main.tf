
provider "aws" {
  region = "us-east-1"
}

# ECR Repository to store the container image
resource "aws_ecr_repository" "app_repo" {
  name = "bedrock-iac-repo"
  image_tag_mutability = "MUTABLE"
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "bedrock-iac-ecs-task-execution-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach ECS Task Execution Role Policy
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM Role for Task (to access Bedrock)
resource "aws_iam_role" "ecs_task_role" {
  name = "bedrock-iac-ecs-task-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Policy to allow access to Bedrock
resource "aws_iam_policy" "bedrock_access_policy" {
  name        = "bedrock-iac-access-policy"
  description = "Allow access to AWS Bedrock Claude models"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:bedrock:*:*:model/anthropic.claude-*"
      }
    ]
  })
}

# Attach Bedrock policy to task role
resource "aws_iam_role_policy_attachment" "bedrock_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.bedrock_access_policy.arn
}

# VPC for Fargate deployment
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  
  tags = {
    Name = "bedrock-iac-vpc"
  }
}

# Public subnet
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "us-east-1${count.index == 0 ? "a" : "b"}"
  map_public_ip_on_launch = true
  
  tags = {
    Name = "bedrock-iac-public-subnet-${count.index}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "bedrock-iac-igw"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  
  tags = {
    Name = "bedrock-iac-public-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Group for the Load Balancer
resource "aws_security_group" "alb_sg" {
  name        = "bedrock-iac-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id
  
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

# Security Group for the ECS Tasks
resource "aws_security_group" "ecs_sg" {
  name        = "bedrock-iac-ecs-sg"
  description = "Security group for ECS tasks"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "bedrock-iac-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = false
}

# ALB Target Group
resource "aws_lb_target_group" "app" {
  name        = "bedrock-iac-target-group"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  
  health_check {
    enabled             = true
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

# ALB Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "bedrock-iac-cluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "bedrock-iac-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  
  container_definitions = jsonencode([
    {
      name      = "bedrock-iac-container"
      image     = "${aws_ecr_repository.app_repo.repository_url}:latest"
      essential = true
      
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]
      
      environment = [
        {
          name  = "AWS_REGION",
          value = "us-east-1"
        }
      ]
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/bedrock-iac"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# Log Group for ECS
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/bedrock-iac"
  retention_in_days = 7
}

# ECS Service
resource "aws_ecs_service" "app" {
  name            = "bedrock-iac-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
  
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "bedrock-iac-container"
    container_port   = 3000
  }
  
  depends_on = [aws_lb_listener.http]
}

# Output the ALB DNS name for access
output "alb_dns_name" {
  description = "Public URL for the application"
  value       = aws_lb.main.dns_name
}

# Output the ECR repository URL for pushing images
output "ecr_repository_url" {
  description = "ECR Repository URL"
  value       = aws_ecr_repository.app_repo.repository_url
}
