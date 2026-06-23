terraform {
  required_providers {
    aws = {
        source = "hashicorp/aws"
        version = "~> 5.0" # here it just means i will tolerate minor fixes update, so that nothing break
    }
  }
}

# my main region
provider "aws" {
    region = "eu-central-1"
}


# my static portfolio site, the reason i encode it is because sometimes it can have weird looking characters that if not properly encoded is hard to put it in the ec2 easily
locals {
    html = base64encode(file("${path.module}/../myPortfolioWebsite/index.html"))
}


# My data sources, these are things from aws that i query for read only only


# this is cloudfronts list of domain prefixes, the reason i have this is because i want my load balancer to only be accessesd with cloud front and i want to security lock it from this origin only
data "aws_ec2_managed_prefix_list" "cf-prefix" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}  


# i didnt' create this vpc, it with the account
data "aws_vpc" "my_vpc" {
    default = true
}

# these are also default subnets of my vpc, i did not create them
data "aws_subnets" "my_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.my_vpc.id]
  }
}

#defining my security groups what can or cant do. these ones i am creating

# secruity group for the application load bancer
resource "aws_security_group" "my_application_load_balancer_sg" {

    name = "my-app-load-balancer-secrity-groups"
    description = "thsi is saying that i only accept http request from cloud front only on port 80"
    vpc_id = data.aws_vpc.my_vpc.id

# incomming requests rule
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        prefix_list_ids = [data.aws_ec2_managed_prefix_list.cf-prefix.id] # here i am basiclly sayin g
    }

    # this is basically saying any rquest can go out of the alb to any ip, any protocol, any port, because it's from the alb, it does not matter
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
         cidr_blocks = ["0.0.0.0/0"]
    }
}

# basically sayin my ec2 only accepts request from my load balancer, but can send anywhere, 
resource "aws_security_group" "my_ec2s_sg" {
  name = "my-ec2s-secruity-groups"
 
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.my_application_load_balancer_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
   vpc_id = data.aws_vpc.my_vpc.id
}


# the load balancer and it's components
resource "aws_lb" "myLoadBalancer" {
  name = "myLoadBalancer"
 
 
 
  security_groups = [aws_security_group.my_application_load_balancer_sg.id] #here assigning my actual secuiryt group i crated above to my lb

 subnets = data.aws_subnets.my_subnets
}

# not hard coded ec2, because they scale up and down, this target groups 
resource "aws_lb_target_group" "my_ec2_groups" {
  name = "myEc2Groups"
  port = 80
  protocol = "HTTP"
}

# this is actually the one responsible to forward the requests from the load balancer to the ec2's
resource "aws_lb_listener" "my_listeners_for_lb" {
  load_balancer_arn = aws_lb.myLoadBalancer.arn
  
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.my_ec2_groups.arn 
  }

  port = 80
  protocol = "HTTP"
}

# my tempalte file for my ec2, this will install nginx and in the website document there is an index html, that has been encoded
resource "aws_launch_template" "my_ec2_template" {
  vpc_security_group_ids = [aws_security_group.my_ec2s_sg.id] # attached to the actual security group
  image_id = "ami-0faab6bdbac9486fb"  #this is ubuntu 22 ( i just used this os personally for a while)
  instance_type = "t3a.nano"  # the cheapsest i could find, but it's still expensive and power full enough for just a portfolio website. ( hopefully this coruce will be graded soon, or it's chop by money, chop my money, chop my money)

#here all am doing is updating my repos, then install nginx, and copy my html from above to the index.html, when nginx ses this it knows, how to serve it ( since it's named index.html) also my site is very basic
# btw the now field is there because witgout it, then nginx wont be up at this moment, it will wait for the next restart
user_data = base64encode(join("\n", [
    "#!/bin/bash",
    "apt-get update -y",
    "apt-get install -y nginx",
    "echo '${local.html}' | base64 -d > /var/www/html/index.html",
    "systemctl enable --now nginx"
  ]))

}


resource "aws_autoscaling_group" "my_web_autoscalers" {
   launch_template {
    id = aws_launch_template.my_ec2_template.id # this is the above one, so my autoscalers always use this when they scale up and dow
    version = "$Latest"
  }
  min_size = 2
  max_size = 5 # hopefully it wont reach here, even the cheap one is expensive.
  vpc_zone_identifier = data.aws_subnets.my_subnets.ids
  target_group_arns = [aws_lb_target_group.my_ec2_groups.arn]
  health_check_type = "ELB"
 
}

# add one ec2
resource "aws_autoscaling_policy" "add_1_ec2" {
  name = "add-1-ec2"
  autoscaling_group_name = aws_autoscaling_group.my_web_autoscalers.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = 1
}

# remove one ec2
resource "aws_autoscaling_policy" "remove_1_ec2" {
  name = "remove-1-ec2"
  autoscaling_group_name = aws_autoscaling_group.my_web_autoscalers.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = -1
}

# How do i decide how to add more ec2's or kill the ones i have
# this defines that a CPU is high
resource "aws_cloudwatch_metric_alarm" "cpu_over_75_percent" {
  alarm_name = "my-ec2-is-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = 2 # as in min
  metric_name = "CPUUtilization" # this is what i am evaluating
  namespace = "AWS/EC2"
  period = 120
  threshold = 75
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.my_web_autoscalers.name
  }
  alarm_actions = [aws_autoscaling_policy.add_1_ec2.arn]
}

# this defines that a CPU is low
resource "aws_cloudwatch_metric_alarm" "cpu_around_25_percent" {
  alarm_name = "cpu_around_25_percent"
    comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  threshold = 25
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.my_web_autoscalers.name
  }
  alarm_actions = [aws_autoscaling_policy.remove_1_ec2.arn]
}


resource "aws_cloudfront_distribution" "cloudfront_cdn" {
  # to access it everywhere
  restrictions {
    geo_restriction {
      restriction_type = "none" 
    }
  }
  # free ssl certificate
  viewer_certificate {
    cloudfront_default_certificate = true 
  }

  enabled     = true             
  origin {
    domain_name = aws_lb.myLoadBalancer.dns_name 
    origin_id   = "alb"                
    custom_origin_config {
      http_port              = 80          
      https_port             = 443         
      origin_protocol_policy = "http-only" 
      origin_ssl_protocols   = ["TLSv1.2"] 
    }
  }
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]     
    cached_methods         = ["GET", "HEAD"]    
    target_origin_id       = "alb"              
    viewer_protocol_policy = "redirect-to-https" 

    forwarded_values {
      query_string = false 

      cookies {
        forward = "none" 
      }
    }

  }

 
  
  
}
