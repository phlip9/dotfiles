# PostgreSQL defaults for new clusters.
{
  # Avoid glibc/ICU collation changes while retaining Unicode text handling.
  # initdb seeds postgres and both templates; existing clusters are unchanged.
  services.postgresql.initdbArgs = [
    "--encoding=UTF8"
    "--locale-provider=builtin"
    "--locale=C.UTF-8"
  ];
}
