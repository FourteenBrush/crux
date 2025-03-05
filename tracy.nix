{ stdenv, fetchFromGitHub }: 

stdenv.mkDerivation {
  pname = "tracy";
  version = "0.11.1";

  src = fetchFromGitHub {
    owner = "wolfpld";
    repo = "tracy";
    url = "https://github.com/wolfpld/tracy.git";
    rev = "v0.11.1";
    sha256 = "";
  };
}
