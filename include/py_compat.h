#ifndef PY_COMPAT_H
#define PY_COMPAT_H

// Define our version of the problematic struct before including Python.h
#define Py_BUILD_CORE
struct _is {
    int dummy;
};

// Include Python headers
#include <Python.h>

// Define a full replacement for PyModuleDef to avoid opaque struct errors
// We use a dummy structure instead of the actual implementation
#ifndef PY_MOD_DEF_FIXED
#define PY_MOD_DEF_FIXED 1
// Redefine PyModuleDef_Base without the problematic _status field
typedef struct {
    PyObject ob_base;
    PyObject* (*m_init)(void);
    int m_index;
    PyObject* m_copy;
} PyModuleDef_Base_Zig;

// Redefine PyModuleDef to use our base definition
typedef struct {
    PyModuleDef_Base_Zig m_base;
    const char* m_name;
    const char* m_doc;
    Py_ssize_t m_size;
    PyMethodDef *m_methods;
    struct PyModuleDef_Slot *m_slots;
    void (*m_traverse)(PyObject *, void *, void *);
    void (*m_clear)(PyObject *);
    void (*m_free)(PyObject *);
} PyModuleDef_Zig;
#endif

// Compatibility function for checking if a PyObject is None
// Returns 1 if the object is None, 0 otherwise
static inline int zig_isNone(PyObject *obj) {
    return obj == Py_None;
}

// Helper functions to access Python singletons
static inline PyObject* zig_get_py_none(void) {
    Py_INCREF(Py_None);
    return Py_None;
}

static inline PyObject* zig_get_py_true(void) {
    Py_INCREF(Py_True);
    return Py_True;
}

static inline PyObject* zig_get_py_false(void) {
    Py_INCREF(Py_False);
    return Py_False;
}

// Function to call a Python function with a single argument
static inline PyObject* zig_call_function_with_arg(PyObject *func, PyObject *arg) {
    return PyObject_CallFunctionObjArgs(func, arg, NULL);
}

// Simple compatibility macros
#ifndef _PyObject_CAST
#define _PyObject_CAST(op) ((PyObject*)(op))
#endif

// Define the unnamed opaque struct as a simple struct with one int field
typedef struct {
    int dummy;
} struct_unnamed_7_zig;

#endif /* PY_COMPAT_H */ 