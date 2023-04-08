variable "name" {
  type        = string
  description = "The name of the automation."
}
variable "targets" {
  type        = map(map(string))
  description = "Map of maps with the required target information."
}
variable "tags" {
  type        = map(any)
  description = "Tags to apply to the resources."
}