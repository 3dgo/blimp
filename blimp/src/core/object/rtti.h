#pragma once

namespace blimp
{

    class Object;

    class Rtti
    {
    public:
        Rtti(std::string class_name, std::function<Object*()> ctor);

        Object* construct_object() const;

        const bool has_constructor()
        {
            return rtti_ctor ? true : false;
        }

        const std::string& get_class_name() const
        {
            return rtti_class_name;
        }

        const STRCODE get_class_hash() const
        {
            return rtti_class_hash;
        }

        static Rtti get_rtti(const std::string& class_name);

        static Object* construct_object(const std::string& class_name);
        static Object* construct_object(const STRCODE class_strcode);

        static Rtti* find_rtti_class(const std::string& class_name);
        static Rtti* find_rtti_class(const STRCODE class_code);

    protected:

        void register_class()
        {
            if (rtti_class_table == nullptr)
            {
                rtti_class_table = new std::map<STRCODE, Rtti*>();
            }
            rtti_class_table->insert(rtti_pair(get_str_code(rtti_class_name.c_str()), this));
        };

    private:
        static std::map<STRCODE, Rtti*>* rtti_class_table;

        STRCODE rtti_class_hash;
        std::string rtti_class_name;
        std::function<Object*()> rtti_ctor;

        typedef std::pair<STRCODE, Rtti*> rtti_pair;
    };

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	External Functions for easy implementation. </summary>
    ///-------------------------------------------------------------------------------------------------
    extern Object* create_object(const std::string& class_name);

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	Class Definition used by all. </summary>
    ///-------------------------------------------------------------------------------------------------
    #define DECLARE_CLASS_DEFINITION(name)																						\
        public:																													\
            static std::string __class##name;																					\
            static Rtti rtti_static_class_info_##name;																			\
            static const std::string& get_class_name() { return name::rtti_static_class_info_##name.get_class_name(); }			\
            static const STRCODE get_class_hash() { return name::rtti_static_class_info_##name.get_class_hash(); }			    \
            virtual const std::string& get_derived_class_name() { return name::__class##name; }									\
            virtual const STRCODE get_derived_class_hash() { return name::rtti_static_class_info_##name.get_class_hash(); }

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	IsA Definition used by all. </summary>
    ///-------------------------------------------------------------------------------------------------
    #define IS_A_BASE_DEFINITION(name)																							\
            virtual bool is_a(STRCODE class_code)																				\
            {																													\
                return (class_code == name::rtti_static_class_info_##name.get_class_hash() ? true : false);						\
            }

    #define IS_A_DEFINITION(name, base)																							\
            virtual bool is_a(STRCODE class_code)																				\
            {																													\
                return (class_code == get_class_hash() ? true : base::is_a(class_code));										\
            }

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	Declaration for Abstract Classes. </summary>
    ///-------------------------------------------------------------------------------------------------
    #define DECLARE_ABSTRACT_BASE_CLASS(name)																					\
        public:																													\
            DECLARE_CLASS_DEFINITION(name)																						\
            IS_A_BASE_DEFINITION(name)

    #define DECLARE_ABSTRACT_DERIVED_CLASS(name, base)																			\
        public:																													\
            DECLARE_CLASS_DEFINITION(name)																						\
            IS_A_DEFINITION(name, base)


    #define IMPLEMENT_ABSTRACT_CLASS(name)																						\
        std::string name::__class##name = #name;																				\
        Rtti name::rtti_static_class_info_##name(std::string(#name), nullptr);

    #define REGISTER_ABSTRACT_CLASS(name)																						\
        name::rtti_static_class_info_##name = Rtti::get_rtti(std::string(#name));

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	Declaration for Dynamic Classes. </summary>
    ///-------------------------------------------------------------------------------------------------
    #define DECLARE_CREATE_CLASS(name)																							\
            static Object* rtti_create_object();																				\
            static name* create() { return new name; }

    #define DECLARE_DYNAMIC_BASE_CLASS(name)																					\
        public:																													\
            DECLARE_CLASS_DEFINITION(name)																						\
            DECLARE_CREATE_CLASS(name)																							\
            IS_A_BASE_DEFINITION(name)

    #define DECLARE_DYNAMIC_DERIVED_CLASS(name, base)																			\
        public:																													\
            DECLARE_CLASS_DEFINITION(name)																						\
            DECLARE_CREATE_CLASS(name)																							\
            IS_A_DEFINITION(name, base)

    #define IMPLEMENT_DYNAMIC_CLASS(name)																						\
        std::string name::__class##name = #name;																				\
        Rtti name::rtti_static_class_info_##name(std::string(#name), name::rtti_create_object);									\
        Object* name::rtti_create_object() { return new name; }

    #define REGISTER_DYNAMIC_CLASS(name)																						\
       name::rtti_static_class_info_##name = Rtti::get_rtti(std::string(#name));

}