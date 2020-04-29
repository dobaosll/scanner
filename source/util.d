module util;

import std.conv;
import std.string;


ubyte subnetworkStr2byte(string subStr) {
  string[] arr = subStr.split(".");
  if (arr.length != 2) {
    throw new Exception("Wrong line address.");
  }
  ubyte main = to!ubyte(arr[0]);
  ubyte middle = to!ubyte(arr[1]);

  return to!ubyte(((main << 4)|middle));
}

string ia2str(ushort addr) {
  string res = to!string(addr >> 12) ~ ".";
  res ~= to!string((addr >> 8) & 0xf) ~ ".";
  res ~= to!string(addr & 0xff);
  return res;
}
