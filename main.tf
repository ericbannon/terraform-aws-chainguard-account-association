module "chainguard-account-association" {
  source = "chainguard-dev/chainguard-account-association/aws"

  group_ids = var.group_ids
  account   = var.account
}
