# Psychedelic dream

# XOR the sine values of X and Y
# and add the current time

LDI 42
MOV R3 R0

GETX R0
SINE R1

GETY R0
SINE R0

XOR R0 R1

GETTIME0 R1
ADD R0 R1

GETTIME1 R1
ADD R0 R1

ADD R0 R3

SETRGB R0

GETTIME1 R1

IFGE R1
SETRGB R1
