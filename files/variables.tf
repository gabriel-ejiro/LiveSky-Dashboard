variable "project" {
  description = "Project name used for resource naming"
  type        = string
  default     = "weatherws"
}

variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-north-1"
}

variable "stage" {
  description = "Deployment stage (e.g., dev, prod)"
  type        = string
  default     = "prod"
}
