provider "aws" {
  region = "${var.aws_region}"
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
}

# VPC
resource "aws_vpc" "default" {
  cidr_block = "10.0.0.0/16"
}
resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.default.id}"
}
resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.default.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.default.id}"
}
resource "aws_vpc_endpoint" "secrets" {
  vpc_id = "${aws_vpc.default.id}"
  service_name = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = ["${aws_vpc.default.main_route_table_id}"]
  policy = <<EOF
{
  "Statement": [
    {
      "Action": "*",
      "Effect": "Allow",
      "Principal": "*",
      "Resource": "*",
      "Principal": "*"
    }
  ]
}
EOF
}

# SUBNETS
resource "aws_subnet" "app_1" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.availability_zone_1}"
  map_public_ip_on_launch = true
}
resource "aws_subnet" "app_2" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.availability_zone_2}"
  map_public_ip_on_launch = true
}
resource "aws_subnet" "db_1" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "${var.availability_zone_1}"
}
resource "aws_subnet" "db_2" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.4.0/24"
  availability_zone       = "${var.availability_zone_2}"
}

# SECURITY GROUPS
resource "aws_security_group" "web" {
  name        = "sg_web"
  vpc_id      = "${aws_vpc.default.id}"

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "app" {
  name        = "sg_app"
  vpc_id      = "${aws_vpc.default.id}"

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "db" {
  name        = "sg_db"
  vpc_id      = "${aws_vpc.default.id}"

  # MySQL access from the VPC
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SSH KEY PAIR
resource "aws_key_pair" "auth" {
  key_name   = "ssh_key"
  public_key = "${file(var.public_key_path)}"
}

# IAM
resource "aws_iam_role" "app" {
    name = "app"
    assume_role_policy = <<EOF
{
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}
resource "aws_iam_instance_profile" "app" {
    name = "app"
    roles = ["${aws_iam_role.app.name}"]
}
resource "aws_iam_role_policy_attachment" "app" {
    role = "${aws_iam_role.app.name}"
    policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# S3
resource "aws_s3_bucket" "client" {
    bucket = "${var.aws_s3_bucket_name}"
    acl = "public-read"

    website {
        index_document = "index.html"
    }
}
resource "aws_s3_bucket" "secrets" {
    bucket = "${var.aws_s3_bucket_name}-secrets"
    policy = <<EOF
{
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${var.aws_s3_bucket_name}-secrets/*",
      "Condition": {
        "StringEquals": {
          "aws:sourceVpce": "${aws_vpc_endpoint.secrets.id}"
        }
      }
    },
		{
			"Effect": "Allow",
			"Principal": {
				"AWS": "${var.account_id}"
			},
			"Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
			"Resource": "arn:aws:s3:::s3-aws-full-stack-shopping-cart-secrets/*"
		}
  ]
}
EOF
}
resource "aws_s3_bucket_object" "secrets" {
  bucket = "${var.aws_s3_bucket_name}-secrets"
  key = "secrets.json"
  content_type = "application/json"
  content = <<EOF
{
  "db": {
    "id": "${aws_db_instance.default.id}",
    "host": "${aws_db_instance.default.address}",
    "port": "${aws_db_instance.default.port}",
    "name": "${aws_db_instance.default.name}",
    "username": "${aws_db_instance.default.username}",
    "password": "${var.db_pass}"
  }
}
EOF
}

# RDS
resource "aws_db_subnet_group" "default" {
  name        = "db_subnet_group"
  subnet_ids  = ["${aws_subnet.db_1.id}", "${aws_subnet.db_2.id}"]
}
resource "aws_db_instance" "default" {
  depends_on             = ["aws_security_group.db"]
  identifier             = "rds"
  allocated_storage      = "10"
  engine                 = "mysql"
  engine_version         = "5.6.27"
  instance_class         = "db.t2.micro"
  name                   = "shoppingcart"
  username               = "admin"
  password               = "${var.db_pass}"
  vpc_security_group_ids = ["${aws_security_group.db.id}"]
  db_subnet_group_name   = "${aws_db_subnet_group.default.id}"
  multi_az               = "true"
}

# DYNAMO
resource "aws_dynamodb_table" "default" {
    name = "Carts"
    read_capacity = 5
    write_capacity = 5
    hash_key = "Email"
    attribute {
      name = "Email"
      type = "S"
    }
}

# ELB & ASG
resource "aws_elb" "web" {
  name = "elb"
  subnets         = ["${aws_subnet.app_1.id}", "${aws_subnet.app_2.id}"]
  security_groups = ["${aws_security_group.web.id}"]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }
}
resource "aws_autoscaling_group" "app" {
  depends_on = ["aws_db_instance.default", "aws_s3_bucket_object.secrets"]
  name                 = "asg"
  vpc_zone_identifier  = ["${aws_subnet.app_1.id}", "${aws_subnet.app_2.id}"]
  max_size             = "4"
  min_size             = "2"
  desired_capacity     = "2"
  force_delete         = true
  launch_configuration = "${aws_launch_configuration.app.name}"
  load_balancers       = ["${aws_elb.web.name}"]
}
resource "aws_launch_configuration" "app" {
  name          = "lc"
  image_id      = "${lookup(var.aws_amis, var.aws_region)}"
  instance_type = "t2.micro"
  iam_instance_profile = "${aws_iam_instance_profile.app.id}"
  security_groups = ["${aws_security_group.app.id}"]
  key_name = "${aws_key_pair.auth.id}"
  user_data = "${file("ec2-startup.sh")}"
}
