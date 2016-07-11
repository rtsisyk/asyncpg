cdef void* codec_map[MAXBUILTINOID]
cdef dict TYPE_CODECS_CACHE = {}
cdef dict EXTRA_CODECS = {}


@cython.final
cdef class Codec:

    def __cinit__(self, uint32_t oid):
        self.oid = oid
        self.type = CODEC_UNDEFINED

    cdef init(self, str name, str schema, str kind,
              CodecType type, CodecFormat format,
              encode_func c_encoder, decode_func c_decoder,
              object py_encoder, object py_decoder,
              Codec element_codec, tuple element_type_oids,
              dict element_names, list element_codecs):

        self.name = name
        self.schema = schema
        self.kind = kind
        self.type = type
        self.format = format
        self.type = type
        self.c_encoder = c_encoder
        self.c_decoder = c_decoder
        self.py_encoder = py_encoder
        self.py_decoder = py_decoder
        self.element_codec = element_codec
        self.element_type_oids = element_type_oids
        self.element_names = element_names
        self.element_codecs = element_codecs

        if type == CODEC_C:
            self.encoder = <codec_encode_func>&self.encode_scalar
            self.decoder = <codec_decode_func>&self.decode_scalar
        elif type == CODEC_ARRAY:
            self.encoder = <codec_encode_func>&self.encode_array
            self.decoder = <codec_decode_func>&self.decode_array
        elif type == CODEC_COMPOSITE:
            self.encoder = <codec_encode_func>&self.encode_composite
            self.decoder = <codec_decode_func>&self.decode_composite
        elif type == CODEC_PY:
            self.encoder = <codec_encode_func>&self.encode_in_python
            self.decoder = <codec_decode_func>&self.decode_in_python
        else:
            raise RuntimeError('unexpected codec type: {}'.format(type))

    cdef Codec copy(self):
        cdef Codec codec

        codec = Codec(self.oid)
        codec.init(self.name, self.schema, self.kind,
                   self.type, self.format,
                   self.c_encoder, self.c_decoder,
                   self.py_encoder, self.py_decoder,
                   self.element_codec,
                   self.element_type_oids, self.element_names,
                   self.element_codecs)

        return codec

    cdef encode_scalar(self, ConnectionSettings settings, WriteBuffer buf,
                       object obj):
        self.c_encoder(settings, buf, obj)

    cdef encode_array(self, ConnectionSettings settings, WriteBuffer buf,
                      object obj):

        cdef WriteBuffer elem_data

        elem_data = WriteBuffer.new()
        for item in obj:
            if item is None:
                elem_data.write_int32(-1)
            else:
                self.element_codec.encode(settings, elem_data, item)

        array_encode_frame(settings, buf, self.element_codec.oid,
                           elem_data, len(obj))

    cdef encode_composite(self, ConnectionSettings settings, WriteBuffer buf,
                          object obj):

        cdef:
            WriteBuffer elem_data
            int32_t i

        elem_data = WriteBuffer.new()
        i = 0
        for item in obj:
            elem_data.write_int32(self.element_type_ids[i])
            if item is None:
                elem_data.write_int32(-1)
            else:
                self.element_codecs[i].encode(settings, elem_data, item)

        record_encode_frame(settings, buf, elem_data, len(obj))

    cdef encode_in_python(self, ConnectionSettings settings, WriteBuffer buf,
                          object obj):

        bb = self.py_encoder(obj)
        if self.format == PG_FORMAT_BINARY:
            bytea_encode(settings, buf, bb)
        else:
            text_encode(settings, buf, bb)

    cdef encode(self, ConnectionSettings settings, WriteBuffer buf,
                object obj):
        return self.encoder(self, settings, buf, obj)

    cdef decode_scalar(self, ConnectionSettings settings, const char *data,
                       int32_t len):
        return self.c_decoder(settings, data, len)

    cdef decode_array(self, ConnectionSettings settings, const char *data,
                      int32_t len):
        cdef:
            tuple result
            int32_t ndims
            uint32_t elem_count
            const char *ptr
            uint32_t i
            int32_t elem_len
            Codec elem_codec

        ndims = hton.unpack_int32(data)
        elem_count = hton.unpack_int32(&data[12])
        ptr = &data[20]

        if ndims > 0:
            elem_codec = self.element_codec
            result = cpython.PyTuple_New(elem_count)
            for i in range(elem_count):
                elem_len = hton.unpack_int32(ptr)
                ptr += 4
                if elem_len == -1:
                    elem = None
                else:
                    elem = elem_codec.decode(settings, ptr, elem_len)
                    ptr += elem_len
                cpython.Py_INCREF(elem)
                cpython.PyTuple_SET_ITEM(result, i, elem)
        else:
            result = ()

        return result

    cdef decode_composite(self, ConnectionSettings settings, const char *data,
                          int32_t len):
        cdef:
            object result
            uint32_t elem_count
            const char *ptr
            uint32_t i
            int32_t elem_len
            uint32_t elem_typ
            uint32_t received_elem_typ
            Codec elem_codec

        elem_count = hton.unpack_int32(data)
        result = record.ApgRecord_New(self.element_names, elem_count)
        ptr = &data[4]
        for i in range(elem_count):
            elem_typ = self.element_type_oids[i]
            received_elem_typ = hton.unpack_int32(ptr)

            if received_elem_typ != elem_typ:
                raise RuntimeError(
                    'unexpected attribute data type: {}, expected {}'
                        .format(received_elem_typ, elem_typ))

            ptr += 4

            elem_len = hton.unpack_int32(ptr)

            ptr += 4

            if elem_len == -1:
                elem = None
            else:
                elem_codec = self.element_codecs[i]
                elem = elem_codec.decode(settings, ptr, elem_len)
                ptr += elem_len

            cpython.Py_INCREF(elem)
            record.ApgRecord_SET_ITEM(result, i, elem)

        return result

    cdef decode_in_python(self, ConnectionSettings settings, const char *data,
                          int32_t len):
        if self.format == PG_FORMAT_BINARY:
            bb = bytea_decode(settings, data, len)
        else:
            bb = text_decode(settings, data, len)

        return self.py_decoder(bb)

    cdef inline decode(self, ConnectionSettings settings, const char *data,
                       int32_t len):
        return self.decoder(self, settings, data, len)

    cdef inline has_encoder(self):
        cdef Codec elem_codec

        if self.c_encoder is not NULL or self.py_encoder is not None:
            return True

        elif self.type == CODEC_ARRAY:
            return self.element_codec.has_encoder()

        elif self.type == CODEC_COMPOSITE:
            for elem_codec in self.element_codecs:
                if not elem_codec.has_encoder():
                    return False
            return True

        else:
            return False

    cdef has_decoder(self):
        cdef Codec elem_codec

        if self.c_decoder is not NULL or self.py_decoder is not None:
            return True

        elif self.type == CODEC_ARRAY:
            return self.element_codec.has_decoder()

        elif self.type == CODEC_COMPOSITE:
            for elem_codec in self.element_codecs:
                if not elem_codec.has_decoder():
                    return False
            return True

        else:
            return False

    cdef is_binary(self):
        return self.format == PG_FORMAT_BINARY

    def __repr__(self):
        return '<Codec oid={} elem_oid={} core={}>'.format(
            self.oid,
            'NA' if self.element_codec is None else self.element_codec.oid,
            has_core_codec(self.oid))

    @staticmethod
    cdef Codec new_array_codec(uint32_t oid,
                               str name,
                               str schema,
                               Codec element_codec):
        cdef Codec codec
        codec = Codec(oid)
        codec.init(name, schema, 'array', CODEC_ARRAY, PG_FORMAT_BINARY,
                   NULL, NULL, None, None, element_codec, None, None, None)
        return codec

    @staticmethod
    cdef Codec new_composite_codec(uint32_t oid,
                                   str name,
                                   str schema,
                                   list element_codecs,
                                   tuple element_type_oids,
                                   dict element_names):
        cdef Codec codec
        codec = Codec(oid)
        codec.init(name, schema, 'composite', CODEC_COMPOSITE,
                   PG_FORMAT_BINARY, NULL, NULL, None, None, None,
                   element_type_oids, element_names, element_codecs)
        return codec

    @staticmethod
    cdef Codec new_python_codec(uint32_t oid,
                                str name,
                                str schema,
                                str kind,
                                object encoder,
                                object decoder,
                                CodecFormat format):
        cdef Codec codec
        codec = Codec(oid)
        codec.init(name, schema, kind, CODEC_PY, format, NULL, NULL,
                   encoder, decoder, None, None, None, None)
        return codec


cdef class DataCodecConfig:
    def __init__(self, cache_key):
        try:
            self._type_codecs_cache = TYPE_CODECS_CACHE[cache_key]
        except KeyError:
            self._type_codecs_cache = TYPE_CODECS_CACHE[cache_key] = {}

        self._local_type_codecs = {}

    def add_types(self, types):
        cdef:
            Codec elem_codec
            list comp_elem_codecs

        for ti in types:
            oid = ti['oid']

            if self.get_codec(oid) is not None:
                continue

            name = ti['name']
            schema = ti['ns']
            array_element_oid = ti['elemtype']
            comp_type_attrs = ti['attrtypoids']
            base_type = ti['basetype']

            if name.startswith('_') and array_element_oid:
                name = '{}[]'.format(name[1:])

            if array_element_oid:
                # Array type
                elem_codec = self.get_codec(array_element_oid)
                if elem_codec is None:
                    raise RuntimeError(
                        'no codec for array element type {}'.format(
                            array_element_oid))
                self._type_codecs_cache[oid] = \
                    Codec.new_array_codec(oid, name, schema, elem_codec)

            elif comp_type_attrs:
                # Composite element
                comp_elem_codecs = []

                for typoid in comp_type_attrs:
                    elem_codec = self.get_codec(typoid)
                    if elem_codec is None:
                        raise RuntimeError(
                            'no codec for composite attribute type {}'.format(
                                typoid))
                    comp_elem_codecs.append(elem_codec)

                self._type_codecs_cache[oid] = \
                    Codec.new_composite_codec(
                        oid, name, schema, comp_elem_codecs,
                        comp_type_attrs,
                        {name: i for i, name in enumerate(ti['attrnames'])})

            elif ti['kind'] == b'd' and base_type:
                elem_codec = self.get_codec(base_type)
                if elem_codec is None:
                    raise RuntimeError(
                        'no codec for array element type {}'.format(
                            base_type))

                self._type_codecs_cache[oid] = elem_codec
            else:
                raise NotImplementedError(
                    'unhandled data type {!r}'.format(ti))

    def add_python_codec(self, typeoid, typename, typeschema, typekind,
                         encoder, decoder, binary):
        if self.get_codec(typeoid) is not None:
            raise ValueError('cannot override codec for type {}'.format(
                typeoid))

        format = PG_FORMAT_BINARY if binary else PG_FORMAT_TEXT

        self._local_type_codecs[typeoid] = \
            Codec.new_python_codec(typeoid, typename, typeschema, typekind,
                                   encoder, decoder, format)

    def set_builtin_type_codec(self, typeoid, typename, typeschema, typekind,
                        alias_to):
        cdef:
            Codec codec
            Codec extra_codec

        if self.get_codec(typeoid) is not None:
            raise ValueError('cannot override codec for type {}'.format(
                typeoid))

        extra_codec = get_extra_codec(alias_to)
        if extra_codec is None:
            raise ValueError('unknown alias target: {}'.format(alias_to))

        codec = extra_codec.copy()
        codec.oid = typeoid
        codec.name = typename
        codec.schema = typeschema
        codec.kind = typekind

        self._local_type_codecs[typeoid] = codec

    def clear_type_cache(self):
        self._type_codecs_cache.clear()

    cdef inline Codec get_codec(self, uint32_t oid):
        cdef Codec codec

        codec = get_core_codec(oid)
        if codec is not None:
            return codec

        try:
            return self._type_codecs_cache[oid]
        except KeyError:
            try:
                return self._local_type_codecs[oid]
            except KeyError:
                return None


cdef inline Codec get_core_codec(uint32_t oid):
    cdef void *ptr
    if oid >= MAXBUILTINOID:
        return None
    ptr = codec_map[oid]
    if ptr is NULL:
        return None
    return <Codec>ptr


cdef inline int has_core_codec(uint32_t oid):
    return codec_map[oid] != NULL


cdef register_core_codec(uint32_t oid,
                         encode_func encode,
                         decode_func decode,
                         CodecFormat format):

    if oid >= MAXBUILTINOID:
        raise RuntimeError(
            'cannot register core codec for OID {}: it is greater '
            'than MAXBUILTINOID'.format(oid))

    cdef:
        Codec codec
        str name
        str kind

    name = TYPEMAP[oid]
    kind = 'array' if oid in TYPE_IS_ARRAY else 'scalar'

    codec = Codec(oid)
    codec.init(name, 'pg_catalog', kind, CODEC_C, format, encode,
               decode, None, None, None, None, None, None)
    cpython.Py_INCREF(codec)  # immortalize
    codec_map[oid] = <void*>codec


cdef register_extra_codec(str name,
                          encode_func encode,
                          decode_func decode,
                          CodecFormat format):
    cdef:
        Codec codec
        str kind

    kind = 'scalar'

    codec = Codec(INVALIDOID)
    codec.init(name, None, kind, CODEC_C, format, encode,
               decode, None, None, None, None, None, None)
    EXTRA_CODECS[name] = codec


cdef inline Codec get_extra_codec(str name):
    return EXTRA_CODECS.get(name)
