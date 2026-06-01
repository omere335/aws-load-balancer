variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "il-central-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "public_key" {
  description = "Public key material for the EC2 key pair (contents of .pub file)"
  type        = string
}

variable "web_server_count" {
  description = "Number of web server containers to run"
  type        = number
  default     = 2
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH into the instance"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy resources into"
  type        = string
  default     = "vpc-0e6ecadab552e1740"
}