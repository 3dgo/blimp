#pragma once

#include <uuid/uuid.h>

namespace blimp
{
    #define UUID                uuid_t
    #define STRCODE				unsigned int
    #define	NONAME				0xf06a6692
    #define UNIQUEID			int

    #define	MATH_HALF_PI		(1.5707963267948966192313216916398f)
    #define	MATH_PI				(3.1415926535897932384626433832795f)
    #define MATH_2PI			(6.283185307179586476925286766559f)
    #define	MATH_180_OVER_PI	(57.295779513082320876798154814105f)
    #define	MATH_PI_OVER_180	(0.01745329251994329576923690768489f)

    #define	RAD_TO_DEG(rad)		(rad*MATH_180_OVER_PI)
    #define	DEG_TO_RAD(deg)		(deg*MATH_PI_OVER_180)

    #define TO_STRING(_arg_)	#_arg_

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	Gets a random float from 0.0 and 1.0. </summary>
    ///-------------------------------------------------------------------------------------------------
    /*inline float rand_float()
    {
        return static_cast<float>((rand()) / (RAND_MAX + 1.0f));
    }*/

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	Gets the a random value clamped between -1.0 and 1.0. </summary>
    ///-------------------------------------------------------------------------------------------------
    /*inline float random_clamped()
    {
        return rand_float() - rand_float();
    }*/

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	A macro that defines maximum. </summary>
    ///-------------------------------------------------------------------------------------------------
    #define max(a,b)            (((a) > (b)) ? (a) : (b))

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	A macro that defines minimum. </summary>
    ///-------------------------------------------------------------------------------------------------
    #define min(a,b)            (((a) < (b)) ? (a) : (b))

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	Generates a hash code using FVN-1. </summary>
    // http://www.isthe.com/chongo/tech/comp/fnv/
    ///-------------------------------------------------------------------------------------------------
    inline STRCODE get_str_code(const char* str)
    {
        const unsigned int fnv_prime = 0x811C9DC5;
        unsigned int hash = 0;
        char end = '\0';

        for (const char* ref = str; *ref != end; ref++)
        {
            hash *= fnv_prime;
            hash ^= *ref;
        }

        return hash;
    }

    inline void create_uuid(UUID& id)
    {
        uuid_generate(id);
    }

    inline std::string uuid_to_string(const UUID& id)
    {
        std::string uuid_string;
        uuid_string.resize(36);
        uuid_unparse(id, uuid_string.data());
        return uuid_string;
    }

    inline STRCODE uuid_to_strcode(UUID& id)
    {
        return get_str_code(uuid_to_string(id).c_str());
    }

    ///-------------------------------------------------------------------------------------------------
    /// <summary>	A macro that defines a runtime error. </summary>
    ///
    /// <remarks>	William Barry, 05/02/2013. </remarks>
    ///
    /// <param name="condition">	The condition. </param>
    /// <param name="message">  	The message. </param>
    ///-------------------------------------------------------------------------------------------------
    #define THROW_RUNTIME_ERROR(condition, message)		\
        if (condition)									\
        {												\
            throw std::runtime_error(message);			\
        }


    ///-------------------------------------------------------------------------------------------------
    /// <summary>	A macro that defines assert. </summary>
    ///
    /// <remarks>	William Barry, 05/02/2013. </remarks>
    ///
    /// <param name="condition">	The condition. </param>
    /// <param name="message">  	The message. </param>
    ///-------------------------------------------------------------------------------------------------
    #ifdef _DEBUG
    #define ASSERT(condition, message) \
            do { \
                if (! (condition)) { \
                    std::cerr << "Assertion `" #condition "` failed in " << __FILE__ \
                              << " line " << __LINE__ << ": " << message << std::endl; \
                    std::exit(EXIT_FAILURE); \
                } \
            } while (false)
    #else
    #define ASSERT(condition, message) do { } while (false)
    #endif

}