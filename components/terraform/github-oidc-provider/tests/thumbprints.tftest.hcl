# Verifies thumbprint handling: default list contains the two well-known
# GitHub Actions OIDC thumbprints, and callers can override. No outbound
# call to GitHub at plan time (we dropped the tls_certificate data source).

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "github-oidc-provider"
}

run "defaults_pin_known_github_thumbprints" {
  command = plan

  assert {
    condition = contains(
      aws_iam_openid_connect_provider.github[0].thumbprint_list,
      "6938fd4d98bab03faadb97b34396831e3780aea1",
    )
    error_message = "Default thumbprint_list must include the primary GitHub OIDC thumbprint."
  }

  assert {
    condition = contains(
      aws_iam_openid_connect_provider.github[0].thumbprint_list,
      "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
    )
    error_message = "Default thumbprint_list must include the secondary GitHub OIDC thumbprint."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com"
    error_message = "Provider URL must point at GitHub's OIDC issuer."
  }

  assert {
    condition = contains(
      aws_iam_openid_connect_provider.github[0].client_id_list,
      "sts.amazonaws.com",
    )
    error_message = "Default client_id_list must include sts.amazonaws.com (the audience AWS expects)."
  }
}

run "caller_can_override_thumbprints" {
  command = plan

  variables {
    thumbprint_list = ["aabbccddeeff00112233445566778899aabbccdd"]
  }

  assert {
    condition = contains(
      aws_iam_openid_connect_provider.github[0].thumbprint_list,
      "aabbccddeeff00112233445566778899aabbccdd",
    )
    error_message = "thumbprint_list override must be honored (custom thumbprint present)."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github[0].thumbprint_list) == 1
    error_message = "thumbprint_list override should replace, not merge - expected exactly 1 entry."
  }
}
