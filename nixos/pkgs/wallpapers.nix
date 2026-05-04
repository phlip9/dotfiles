{
  fetchurl,
  matugen,
}:

rec {
  recurseForDerivations = true;

  default = dunes;

  # 2560x1440
  dunes = fetchurl {
    url = "https://phlip9.com/notes/__pub/sand_dunes_cropped.jpeg";
    hash = "sha256-PITohebOHZ68rWOXUbpcXYy8rqHq7/atdY66zff91cQ=";
    passthru = {
      configs = matugen.mkConfigs {
        name = "dunes";
        image = dunes;
        mode = "dark";
        contrast = "0";
        type = "scheme-neutral";
        sourceColorIndex = "0";
      };
    };
  };
}
