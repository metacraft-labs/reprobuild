def used_a(x); x + 1; end
def used_b(x); x * 2; end
def unused_c(x); x - 99; end
def main; puts(used_a(2) + used_b(3)); end
main
