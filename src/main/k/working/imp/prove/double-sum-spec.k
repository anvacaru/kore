// Copyright (c) 2016-2018 K Team. All Rights Reserved.


module VERIFICATION
  imports IMP

// verification ids
  syntax Id ::= "n"     [token]
              | "p"     [token]
              | "sum"   [token]
endmodule

module DOUBLE-SUM-SPEC
  imports IMP
  imports VERIFICATION


rule
    <k>
      while (!(p <= 0)) {
        sum = sum + p + p + p + p + p + p;
        p = p + -1;
      }
    =>
      .K
    ...</k>
  <state>
      n   |-> N:Int
      p   |-> (P:Int => 0)
      sum |-> (S:Int => S +Int (3 *Int ((P +Int 1) *Int P)))
  </state>
requires P >=Int 0

rule
    <k>
      while (!(n <= 0)) {
        p = n;
        n = n + -1;
        while (!(p <= 0)) {
            sum = sum + p + p + p + p + p + p;
            p = p + -1;
        }
      }
    =>
      .K
    ...</k>
  <state>
      n   |-> (N:Int => 0)
      p   |-> 0
      sum |-> (S:Int => S +Int (N *Int (N +Int 1) *Int (N +Int 2)))
  </state>
requires N >=Int 0

rule
    <k>
      int n, p, sum;
      n = N:Int;
      sum = 0;
      p = 0;
      while (!(n <= 0)) {
        p = n;
        n = n + -1;
        while (!(p <= 0)) {
            sum = sum + p + p + p + p + p + p;
            p = p + -1;
        }
      }
    =>
      .K
    </k>
  <state>
    .Map
  =>
      n   |-> 0
      p   |-> 0
      sum |-> (N *Int (N +Int 1) *Int (N +Int 2))
  </state>
requires N >=Int 0

endmodule
