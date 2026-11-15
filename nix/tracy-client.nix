# Tracy client library
{ stdenv, lib, cmake, tracy }: 

stdenv.mkDerivation {
  pname = "tracy-client";
  
  # Same source as the profiler, so the protocol versions always match
  inherit (tracy) version src;
  
  nativeBuildInputs = [ cmake ];
  
  cmakeFlags = [
    "-DBUILD_SHARED_LIBS=ON"
    "-DTRACY_STATIC=OFF"
  ];
}
