#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#define NEED_newSVpvn_flags_GLOBAL
#include "ppport.h"

#include "define.h"
#include "type.h"

/* Long */
int64_t unpack_long(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    if (UNLIKELY(len - *pos < 8))
        croak("unpack_long: input too short. Data corrupted?");

    /* I'm going to assume a LE system here. If that's not the case, let's hope $user ran the tests. */
    uint32_t first_half  = ntohl(*(uint32_t*)(input+*pos));
    uint32_t second_half = ntohl(*(uint32_t*)(input+*pos+4));
    int64_t result = (((int64_t)first_half) << 32) | ((int64_t)second_half);

    *pos += 8;
    return result;
}

/* Tinyint */
int8_t unpack_tinyint(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    if (UNLIKELY(len - *pos < 1))
        croak("unpack_tinyint: input too short. Data corrupted?");
    int8_t result = input[*pos];
    *pos += 1;
    return result;
}

/* Int */
int32_t unpack_int(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    if (UNLIKELY(len - *pos < 4))
        croak("unpack_int: input too short. Data corrupted?");
    int32_t result = (int32_t)ntohl(*(uint32_t*)(input+*pos));
    *pos += 4;
    return result;
}

/* Float */
float unpack_float(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    int32_t result_bytes = unpack_int(aTHX_ input, len, pos);
    float result = *((float*)&result_bytes);
    return result;
}

/* Double */
double unpack_double(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    int64_t result_bytes = unpack_long(aTHX_ input, len, pos);
    double result = *((double*)&result_bytes);
    return result;
}

/* Short */
int unpack_short_nocroak(pTHX_ char *input, STRLEN len, STRLEN *pos, uint16_t *out)
{
    if (UNLIKELY(len - *pos < 2))
        return -1;
    *out = ntohs(*(uint16_t*)(input+*pos));
    *pos += 2;
    return 0;
}

uint16_t unpack_short(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    uint16_t out;
    if (UNLIKELY(unpack_short_nocroak(aTHX_ input, len, pos, &out) != 0))
        croak("unpack_short: invalid input");
    return out;
}

/* Bytes */
int unpack_short_bytes(pTHX_ char *input, STRLEN len, STRLEN *pos, char **output, STRLEN *outlen)
{
    uint16_t bytes_length = unpack_short(aTHX_ input, len, pos);
    if (UNLIKELY(len - *pos < bytes_length))
        croak("unpack_short_bytes: input too short. Data corrupted?");

    *output = input + *pos;
    *outlen = bytes_length;
    *pos += bytes_length;

    return 0;
}

/* Bytes */
int unpack_bytes(pTHX_ char *input, STRLEN len, STRLEN *pos, char **output, STRLEN *outlen)
{
    int32_t bytes_length = unpack_int(aTHX_ input, len, pos);
    if (bytes_length < 0) {
        return 1;
    }

    if (UNLIKELY(len - *pos < bytes_length))
        croak("unpack_bytes: input too short. Data corrupted?");

    *output = input + *pos;
    *outlen = bytes_length;
    *pos += bytes_length;

    return 0;
}

SV *unpack_bytes_sv(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    char *bytes;
    STRLEN bytes_len;

    if (unpack_bytes(aTHX_ input, len, pos, &bytes, &bytes_len) == 0) {
        return newSVpvn(bytes, bytes_len);
    } else {
        return &PL_sv_undef;
    }
}

/* String */
int unpack_string_nocroak(pTHX_ char *input, STRLEN len, STRLEN *pos, char **output, STRLEN *outlen)
{
    uint16_t string_length = unpack_short(aTHX_ input, len, pos);

    if (UNLIKELY(len - *pos < string_length))
        return -1;

    *output = input + *pos;
    *outlen = string_length;
    *pos += string_length;

    return 0;
}

void unpack_string(pTHX_ char *input, STRLEN len, STRLEN *pos, char **output, STRLEN *outlen)
{
    if (UNLIKELY(unpack_string_nocroak(aTHX_ input, len, pos, output, outlen)) != 0)
        croak("unpack_string: input invalid");
}

SV *unpack_string_sv(pTHX_ char *input, STRLEN len, STRLEN *pos)
{
    char *string;
    STRLEN str_len;
    unpack_string(aTHX_ input, len, pos, &string, &str_len);
    return newSVpvn_utf8(string, str_len, 1);
}

/* Long string */
void unpack_long_string(pTHX_ char *input, STRLEN len, STRLEN *pos, char **output, STRLEN *outlen)
{
    int32_t string_length = unpack_int(aTHX_ input, len, pos);

    if (UNLIKELY(string_length < 0 || (len - *pos < string_length)))
        croak("unpack_long_string: input too short. Data corrupted?");

    *output = input + *pos;
    *outlen = string_length;
    *pos += string_length;
}
