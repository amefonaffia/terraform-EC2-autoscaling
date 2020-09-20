provider "aws"{
    region = "us-west-1"
}


output "app-URL" {
    value = "http://${aws_lb.app-lb.dns_name}/index.html"
}


#######################
# SNS
#######################
resource "aws_sns_topic" "updates" {
  name = "ScalingNotificationTopic"
}

resource "aws_sqs_queue" "updates_queue" {
  name = "updates-queue"
}

resource "aws_sns_topic_subscription" "updates_sqs_target" {
  topic_arn = aws_sns_topic.updates.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.updates_queue.arn
}

resource "aws_autoscaling_notification" "asg-notifications" {
  group_names = [
    aws_autoscaling_group.asg.name
  ]

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]

  topic_arn = aws_sns_topic.updates.arn
}

#######################
# AutoScaling
#######################
resource "aws_autoscaling_group" "asg" {
  availability_zones = ["us-west-1a", "us-west-1c"]
  desired_capacity   = 1
  max_size           = 3
  min_size           = 1
  health_check_grace_period = 60
  health_check_type         = "ELB"
  force_delete              = true
  launch_configuration      = aws_launch_configuration.as_conf.name
  target_group_arns = [aws_lb_target_group.app-lb-tg.arn]
  depends_on = [aws_sns_topic.updates]
}


resource "aws_autoscaling_attachment" "asg_attachment_ELB" {
  autoscaling_group_name = aws_autoscaling_group.asg.id
  alb_target_group_arn   = aws_lb_target_group.app-lb-tg.arn
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-trusty-14.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_launch_configuration" "as_conf" {
  name_prefix   = "aws-launch-config"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name = "deployer-key"
  security_groups = [aws_security_group.lb_sg.id]
  lifecycle {
    create_before_destroy = true
  }
  user_data = file("./install_apache.sh")
}

resource "aws_key_pair" "deployer-key" {
  key_name   = "deployer-key"
  public_key = file("./id_rsa.pub")
}


#######################
# VPC
#######################

resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "main"
  }
}
variable "azs" {
	type = list
	default = ["us-west-1a", "us-west-1c"]
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet)
  vpc_id = aws_vpc.main.id
  cidr_block = element(var.public_subnet,count.index)
  availability_zone = element(var.azs,count.index)
  tags = {
    Name = "Subnet-${count.index+1}"
  }
  map_public_ip_on_launch = true
}

variable "public_subnet" {
	type = list(string)
	default = ["10.0.1.0/24", "10.0.2.0/24"]
}


# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main"
  }
}

# Route table: attach Internet Gateway 
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "publicRouteTable"
  }
}

# Route table association with public subnets
resource "aws_route_table_association" "a" {
  count = length(var.public_subnet)
  subnet_id      = element(aws_subnet.public.*.id,count.index)
  #subnet_id      = element(aws_subnet.public.*.id,count.index)
  route_table_id = aws_route_table.public_rt.id
}

#######################
# Security Group
#######################

resource "aws_security_group" "lb_sg" {
  name        = "allow_HTTP(s)"
  description = "Allow HTTP(s) inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "TLS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" #all
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_http"}
}

#######################
# APP Load balancer
#######################


resource "aws_s3_bucket" "lb_logs" {
  bucket = "app-lb-bucket"
  tags = {
    Name        = "app-lb-Bucket"
    Environment = "Dev"
  }
}

resource "aws_s3_bucket_policy" "b" {
  bucket = aws_s3_bucket.lb_logs.id

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:*",
            "Resource": "*"
        }
    ]
}
POLICY
}

resource "aws_lb" "app-lb" {
  name               = "app-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = aws_subnet.public.*.id
  ip_address_type    = "ipv4"
  enable_deletion_protection = false

  access_logs {
    bucket  = aws_s3_bucket.lb_logs.bucket
    prefix  = "app-lb-lb"
    enabled = true
  }

  tags = {
    Environment = "Dev"
  }
}

resource "aws_lb_target_group" "app-lb-tg" {
  name               = "elb"
  #availability_zones = ["us-west-1a", us-west-1c"]
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    path = "/index.html"
    timeout = 5
   # healthy_threshold   = 2
    unhealthy_threshold = 5
    # target              = "HTTP:8000/"
    interval            = 30
  }
}

resource "aws_lb_listener" "app-lb-listen" {
  load_balancer_arn = aws_lb.app-lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app-lb-tg.arn
  }
}
