# OpenTofu config for `phlip9.com` DNS zone on Cloudflare
{ config, ... }:

let
  zone = config.data.cloudflare_zone.phlip9_com;
  zone_id = zone "id";
  account_id = zone "account.id";
in

{
  # DNS zone data source
  data.cloudflare_zone.phlip9_com.filter.name = "phlip9.com";

  # cache.phlip9.com - nix cache - R2 custom domain
  resource.cloudflare_r2_custom_domain.cache_phlip9_com = {
    inherit account_id zone_id;
    bucket_name = "phlip9-nix-cache";
    domain = "cache.phlip9.com";
    enabled = true;
    min_tls = "1.2";
  };

  # DNS records
  resource.cloudflare_dns_record = {
    # github pages IPs at the apex
    a_github_pages_108_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "A";
      content = "185.199.108.153";
      ttl = 1; # automatic
      proxied = false;
    };
    a_github_pages_109_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "A";
      content = "185.199.109.153";
      ttl = 1; # automatic
      proxied = false;
    };
    a_github_pages_110_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "A";
      content = "185.199.110.153";
      ttl = 1; # automatic
      proxied = false;
    };
    a_github_pages_111_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "A";
      content = "185.199.111.153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_0_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "AAAA";
      content = "2606:50c0:8000::153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_1_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "AAAA";
      content = "2606:50c0:8001::153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_2_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "AAAA";
      content = "2606:50c0:8002::153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_3_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "AAAA";
      content = "2606:50c0:8003::153";
      ttl = 1; # automatic
      proxied = false;
    };

    # github pages CNAME for www.phlip9.com subdomain
    cname_www_phlip9_com = {
      inherit zone_id;
      name = "www.phlip9.com";
      type = "CNAME";
      content = "phlip9.github.io";
      ttl = 1; # automatic
      proxied = false;
      settings.flatten_cname = false;
    };

    a_home_phlip9_com = {
      inherit zone_id;
      name = "home.phlip9.com";
      type = "A";
      content = "174.160.113.34";
      ttl = 120;
      proxied = false;
    };
    aaaa_home_phlip9_com = {
      inherit zone_id;
      name = "home.phlip9.com";
      type = "AAAA";
      content = "2001:558:6045:110:bc2c:4e7:cc33:9c61";
      proxied = false;
      ttl = 120;
    };

    a_omnara1_phlip9_com = {
      inherit zone_id;
      name = "omnara1.phlip9.com";
      type = "A";
      content = "95.217.195.225";
      ttl = 1; # automatic
      proxied = false;
      comment = "Hetzner omnara bare metal machine";
    };
    aaaa_omnara1_phlip9_com = {
      inherit zone_id;
      name = "omnara1.phlip9.com";
      type = "AAAA";
      content = "2a01:4f9:4a:52de::2";
      ttl = 1; # automatic
      proxied = false;
      comment = "Hetzner omnara bare metal machine";
    };

    # # Managed by R2 custom domain
    # cname_cache_phlip9_com = {
    #   inherit zone_id;
    #   name = "cache.phlip9.com";
    #   type = "CNAME";
    #   content = "public.r2.dev";
    #   ttl = 1; # automatic
    #   proxied = true;
    #   settings.flatten_cname = false;
    # };

    cname_ci_phlip9_com = {
      inherit zone_id;
      name = "ci.phlip9.com";
      type = "CNAME";
      content = "omnara1.phlip9.com";
      ttl = 1; # automatic
      proxied = false;
      settings.flatten_cname = false;
      comment = "nixbot CI machine";
    };
    cname_grafana_phlip9_com = {
      inherit zone_id;
      name = "grafana.phlip9.com";
      type = "CNAME";
      content = "omnara1.phlip9.com";
      ttl = 1; # automatic
      proxied = false;
      settings.flatten_cname = false;
      comment = "Grafana dashboards";
    };
    cname_paseo_phlip9_com = {
      inherit zone_id;
      name = "paseo.phlip9.com";
      type = "CNAME";
      content = "omnara1.phlip9.com";
      ttl = 1; # automatic
      proxied = false;
      settings.flatten_cname = false;
      comment = "paseo-server";
    };
    cname_relay_paseo_phlip9_com = {
      inherit zone_id;
      name = "relay.paseo.phlip9.com";
      type = "CNAME";
      content = "omnara1.phlip9.com";
      ttl = 1; # automatic
      proxied = false;
      settings.flatten_cname = false;
      comment = "paseo-relay";
    };

    txt_bitcoin_payment_phlip9_com = {
      inherit zone_id;
      name = "me.user._bitcoin-payment.phlip9.com";
      type = "TXT";
      content = "\"bitcoin:?lno=lno1pgt9qcteyp6x7grsdp5kc6tsgpkx27r99eshquqsaqp3ffm4y0gae0zak4sgrmwtcf9tsg9ntc6r5mr8dytkmec8c9udg4craxk67q6g278hz9xcff7l43ezr0my80qrr96042usqep8ywgzwzysyqeljhsx00th9t4493m7e6t2avtwjne0gk2ws3pcczuvt38pnllz5qqr8chcxdl00435dw4ljmrlcqwvcqzh6t3ny5\" \"07k5uh2xu6h8mxvrmtty6r727mwgztyt69k3892x5sy262zeszaarvjjxvyj7an27yxaq8clnufkv8vg8s5ltgj2rlgfc44yjhec3sqtpyel38z0ejpfvuzvz6dldxpzsh8gkmx4k52eulvk5596xc872c3y2rpwu83nl680uq6j0rkys0wp5xjmrfwpqxcetcv5hxzurszcss8azrre376fp00yla7ar09spafgwarpykfajqkp537f8m5e4pg\" \"vak\"";
      ttl = 1; # automatic
      proxied = false;
    };
    txt_dmarc_phlip9_com = {
      inherit zone_id;
      name = "_dmarc.phlip9.com";
      type = "TXT";
      content = "\"v=DMARC1; p=none; rua=mailto:17e811d5df734db59536a7aac83880a1@dmarc-reports.cloudflare.net\"";
      ttl = 1; # automatic
      proxied = false;
    };
    txt_spf_phlip9_com = {
      inherit zone_id;
      name = "phlip9.com";
      type = "TXT";
      content = "\"v=spf1 include:_spf.mx.cloudflare.net ~all\"";
      ttl = 1; # automatic
      proxied = false;
    };

    # # Managed by Cloudflare Email Service
    # mx_route1_phlip9_com = {
    #   inherit zone_id;
    #   name = "phlip9.com";
    #   type = "MX";
    #   content = "route1.mx.cloudflare.net";
    #   ttl = 1; # automatic
    #   proxied = false;
    #   priority = 77;
    # };
    # mx_route2_phlip9_com = {
    #   inherit zone_id;
    #   name = "phlip9.com";
    #   type = "MX";
    #   content = "route2.mx.cloudflare.net";
    #   ttl = 1; # automatic
    #   proxied = false;
    #   priority = 57;
    # };
    # mx_route3_phlip9_com = {
    #   inherit zone_id;
    #   name = "phlip9.com";
    #   type = "MX";
    #   content = "route3.mx.cloudflare.net";
    #   ttl = 1; # automatic
    #   proxied = false;
    #   priority = 70;
    # };
    # txt_dkim_cf2024_1_phlip9_com = {
    #   inherit zone_id;
    #   name = "cf2024-1._domainkey.phlip9.com";
    #   type = "TXT";
    #   content =
    #     "\"v=DKIM1; h=sha256; k=rsa; "
    #     + "p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78k\" \"m4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB\"";
    #   ttl = 1; # automatic
    #   proxied = false;
    # };
  };
}
