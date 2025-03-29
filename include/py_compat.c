#include <Python.h>

/**
 * Helper functions for Zig to access Python singletons and avoid ABI issues 
 */

// Get Python None and increment its reference count
PyObject* zig_get_py_none(void) {
    Py_INCREF(Py_None);
    return Py_None;
}

// Get Python True and increment its reference count
PyObject* zig_get_py_true(void) {
    Py_INCREF(Py_True);
    return Py_True;
}

// Get Python False and increment its reference count
PyObject* zig_get_py_false(void) {
    Py_INCREF(Py_False);
    return Py_False;
}

// Check if a PyObject is None
int zig_is_py_none(PyObject* obj) {
    return obj == Py_None;
}

// Call a Python function with a single argument
PyObject* zig_call_function_with_arg(PyObject* func, PyObject* arg) {
    return PyObject_CallFunctionObjArgs(func, arg, NULL);
}

// Safe wrappers for PyThreadState functions to avoid embedding opaque types in Zig
PyThreadState* zig_py_thread_state_get(void) {
    return PyThreadState_Get();
}

PyThreadState* zig_py_thread_state_swap(PyThreadState* new_thread_state) {
    return PyThreadState_Swap(new_thread_state);
}

PyInterpreterState* zig_py_thread_state_get_interp(PyThreadState* thread_state) {
    return PyThreadState_GetInterpreter(thread_state);
}

// Wrappers for Python C API functions that were missing in the linker errors
void zig_py_incref(PyObject* obj) {
    Py_INCREF(obj);
}

void zig_py_decref(PyObject* obj) {
    Py_DECREF(obj);
}

int zig_py_bool_check(PyObject* obj) {
    return PyBool_Check(obj);
}

int zig_py_bytes_check(PyObject* obj) {
    return PyBytes_Check(obj);
}

int zig_py_capsule_check_exact(PyObject* obj) {
    return PyCapsule_CheckExact(obj);
}

int zig_py_coro_check_exact(PyObject* obj) {
    return PyCoro_CheckExact(obj);
}

int zig_py_dict_check(PyObject* obj) {
    return PyDict_Check(obj);
}

int zig_py_float_check(PyObject* obj) {
    return PyFloat_Check(obj);
}

int zig_py_list_check(PyObject* obj) {
    return PyList_Check(obj);
}

int zig_py_long_check(PyObject* obj) {
    return PyLong_Check(obj);
}

int zig_py_tuple_check(PyObject* obj) {
    return PyTuple_Check(obj);
}

int zig_py_unicode_check(PyObject* obj) {
    return PyUnicode_Check(obj);
} 