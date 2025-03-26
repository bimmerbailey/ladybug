// Uncomment pragma once to prevent multiple inclusion
#pragma once

// Include guards
#ifndef PYTHON_WRAPPER_H
#define PYTHON_WRAPPER_H

// Include stddef.h for size_t
#include <stddef.h>

// Only include these definitions if Python.h is not already included
#ifndef _PYTHON_H

// Basic type definitions we need from Python
typedef struct _object PyObject;
typedef int Py_ssize_t;
typedef unsigned char uint8_t;

// Vectorcall definitions
#define PY_VECTORCALL_ARGUMENTS_OFFSET ((size_t)1 << (8 * sizeof(size_t) - 1))
typedef PyObject *(*vectorcallfunc)(PyObject *callable, PyObject *const *args, size_t nargsf, PyObject *kwnames);

// Slot numbers for vectorcall
#define Py_tp_vectorcall_offset 48

// Declare our own struct to replace the opaque one
typedef struct {
    char _dummy[16];
} _PyStatus;

// Declare struct_unnamed_7 explicitly
typedef struct {
    char _dummy[16];
} struct_unnamed_7;

// Python reference counting
void Py_INCREF(PyObject *o);
void Py_DECREF(PyObject *o);

// Standard Python objects
extern PyObject *Py_None;
extern PyObject *Py_True;
extern PyObject *Py_False;

// Function declarations for Python API
int Py_IsInitialized(void);
void Py_Initialize(void);
void Py_Finalize(void);
PyObject* PyImport_Import(PyObject *name);
PyObject* PyObject_GetAttr(PyObject *o, PyObject *attr_name);
PyObject* PyObject_GetAttrString(PyObject *o, const char *attr_name);
PyObject* PyUnicode_FromStringAndSize(const char *u, Py_ssize_t size);
const char* PyUnicode_AsUTF8(PyObject *unicode);
int PyErr_Occurred(void);
void PyErr_Print(void);
void PyErr_Clear(void);
int PyCallable_Check(PyObject *o);
PyObject* PyDict_New(void);
int PyDict_SetItem(PyObject *p, PyObject *key, PyObject *val);
int PyDict_Next(PyObject *p, Py_ssize_t *ppos, PyObject **key, PyObject **value);
int PyList_Check(PyObject *p);
PyObject* PyList_New(Py_ssize_t size);
int PyList_SetItem(PyObject *p, Py_ssize_t index, PyObject *item);
PyObject* PyList_GetItem(PyObject *p, Py_ssize_t index);
int PyTuple_Check(PyObject *p);
PyObject* PyTuple_New(Py_ssize_t size);
int PyTuple_SetItem(PyObject *p, Py_ssize_t pos, PyObject *o);
PyObject* PyTuple_GetItem(PyObject *p, Py_ssize_t pos);
PyObject* PyLong_FromLongLong(long long v);
long long PyLong_AsLongLong(PyObject *obj);
PyObject* PyFloat_FromDouble(double v);
double PyFloat_AsDouble(PyObject *pyfloat);
PyObject* PyBool_FromLong(long v);
int PyUnicode_Check(PyObject *o);
int PyBool_Check(PyObject *o);
int PyLong_Check(PyObject *o);
int PyFloat_Check(PyObject *o);
int PyDict_Check(PyObject *p);
int PyBytes_Check(PyObject *o);
int PyBytes_AsStringAndSize(PyObject *obj, char **buffer, Py_ssize_t *length);
PyObject* PyErr_SetString(PyObject *type, const char *message);
PyObject* PyCapsule_New(void *pointer, const char *name, void (*destructor)(PyObject *));
void* PyCapsule_GetPointer(PyObject *capsule, const char *name);
int PyCapsule_CheckExact(PyObject *p);
PyObject* PyCFunction_New(void *ml, PyObject *self);
PyObject* PyObject_CallFunctionObjArgs(PyObject *callable, ...);
PyObject* PyObject_CallObject(PyObject *callable, PyObject *args);
PyObject* PyObject_Call(PyObject *callable, PyObject *args, PyObject *kwargs);
PyObject* PyImport_ImportModule(const char *name);
int PyTuple_Size(PyObject *p);
int PyList_Size(PyObject *p);
int PyCoro_CheckExact(PyObject *op);

#endif // _PYTHON_H

// Our shim functions that are safer to use (always available regardless of Python.h)
static inline PyObject* zig_getPyNone(void) {
    return Py_None;
}

static inline PyObject* zig_getPyTrue(void) {
    return Py_True;
}

static inline PyObject* zig_getPyFalse(void) {
    return Py_False;
}

static inline void zig_incref(PyObject* obj) {
    Py_INCREF(obj);
}

static inline void zig_decref(PyObject* obj) {
    Py_DECREF(obj);
}

static inline int zig_isNone(PyObject* obj) {
    return obj == Py_None;
}

#endif // PYTHON_WRAPPER_H 