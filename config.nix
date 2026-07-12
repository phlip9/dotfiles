# OpenTofu/Terraform config.tf in nix with terranix
{ ... }:

let
  cf_account_id = "30faeb30dcb2a77a72fdc0948c99de62";
in

{
  imports = [
    # Cloudflare DNS zones
    ./ops/zone/phlip9.com.nix
    ./ops/zone/philip9.com.nix
  ];

  # Inputs
  #
  # Envs:
  # - $AWS_ACCESS_KEY_ID
  # - $AWS_SECRET_ACCESS_KEY
  # - $CLOUDFLARE_API_TOKEN
  variable = {
    # terraform S3 backend encryption passphrase
    passphrase = {
      type = "string";
      sensitive = true;
      ephemeral = true;
    };
  };

  # Terraform config
  terraform = {
    required_version = "~> 1.11";

    required_providers = {
      cloudflare.source = "cloudflare/cloudflare";
    };

    # Use Cloudflare R2 bucket as our terraform remote backend
    # <https://developers.cloudflare.com/terraform/advanced-topics/remote-backend/>
    #
    # After creating R2 bucket, put these two secrets into ops/secrets.yaml
    # - $AWS_ACCESS_KEY_ID
    # - $AWS_SECRET_ACCESS_KEY
    backend.s3 = {
      bucket = "phlip9-terraform-backend";
      key = "phlip9/dotfiles/default/terraform.tfstate";
      region = "auto";
      skip_credentials_validation = true;
      skip_metadata_api_check = true;
      skip_region_validation = true;
      skip_requesting_account_id = true;
      skip_s3_checksum = true;
      use_path_style = true;
      # access_key = ""; # $AWS_ACCESS_KEY_ID
      # secret_key = ""; # $AWS_SECRET_ACCESS_KEY
      endpoints = {
        s3 = "https://${cf_account_id}.r2.cloudflarestorage.com";
      };
    };

    # configure state/plan encryption
    # <https://opentofu.org/docs/language/state/encryption/>
    encryption = {
      key_provider.pbkdf2.tf_encryption_key = {
        passphrase = "\${ var.passphrase }";
      };
      method.aes_gcm.tf_encryption_key_method = {
        keys = "key_provider.pbkdf2.tf_encryption_key";
      };
      state = {
        enforced = true;
        method = "method.aes_gcm.tf_encryption_key_method";
      };
      plan = {
        enforced = true;
        method = "method.aes_gcm.tf_encryption_key_method";
      };
    };
  };

  # Cloudflare provider config
  # - $CLOUDFLARE_API_TOKEN
  #
  # Create Cloudflare Account API token
  # - Token name: "phlip9-dotfiles-terranix"
  # - Permission policies:
  #
  #   - Entire Account (+ Add Policy)
  #     - Developer Platform
  #       - Workers R2 Storage: Read and Edit
  #     - DNS & Zones:
  #       - Account DNS Settings: Read and Edit
  #     - Rules & Configuration:
  #       - Account Rule Lists: Read and Edit
  #       - Account Rulesets: Read and Edit
  #       - Account Transform Rules: Read and Edit
  #
  #   - All Domains (+ Add Policy)
  #     - DNS & Zones:
  #       - DNS: Read and Edit
  #       - Zone: Read and Edit
  #       - Zone DNS Settings: Read and Edit
  #       - Zone Settings: Read and Edit
  #       - Zone Versioning: Read and Edit
  #
  # - Expiration: No expiration
  # - Client IP address filtering: None
  provider.cloudflare = { };
}
