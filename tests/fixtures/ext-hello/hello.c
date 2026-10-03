/* Smallest extension that exercises phpize/configure/make/install: two
 * functions, no INI, no globals. Written to compile unchanged on every PHP
 * from 7.0 to 8.5, so it sticks to what exists on all of them
 * (zend_parse_parameters_none, one-argument RETURN_STRING, explicit arginfo). */
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include "php.h"
#include "php_hello.h"

ZEND_BEGIN_ARG_INFO_EX(arginfo_hello_world, 0, 0, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_hello_api, 0, 0, 0)
ZEND_END_ARG_INFO()

PHP_FUNCTION(hello_world)
{
	if (zend_parse_parameters_none() == FAILURE) {
		return;
	}
	RETURN_STRING("hello from ext-builder");
}

/* The Zend module API number this .so was compiled against. */
PHP_FUNCTION(hello_api)
{
	if (zend_parse_parameters_none() == FAILURE) {
		return;
	}
	RETURN_LONG(ZEND_MODULE_API_NO);
}

static const zend_function_entry hello_functions[] = {
	PHP_FE(hello_world, arginfo_hello_world)
	PHP_FE(hello_api, arginfo_hello_api)
	PHP_FE_END
};

zend_module_entry hello_module_entry = {
	STANDARD_MODULE_HEADER,
	"hello",
	hello_functions,
	NULL,
	NULL,
	NULL,
	NULL,
	NULL,
	PHP_HELLO_VERSION,
	STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_HELLO
ZEND_GET_MODULE(hello)
#endif
